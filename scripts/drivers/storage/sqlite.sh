#!/usr/bin/env bash
# sqlite storage driver (built-in, default).
#
# Implements the storage contract (docs/spec/driver-interface.md §2, ADR 0003)
# over SQLite. Sourced by the storage facade (lib/storage.sh, agmsg_storage_load),
# so agmsg_db_path / agmsg_sqlite / agmsg_sql_readfile_path from storage.sh are in
# scope. State is an append-only `events` log (canonical JSONL: message_sent /
# message_read); the legacy `messages` table is read for back-compat (§2.4).
#
# The delivery cursor (§2.2) is the events.seq autoincrement, returned to core as
# an opaque decimal string — core never parses it. Read-marking is recipient-
# scoped ((team, agent)) and idempotent.

# --- helpers ---------------------------------------------------------------

_sqlite_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# UUIDv7: 48-bit ms timestamp + version/variant + random. python3 preferred;
# fall back to a /dev/urandom shell build. No counter file (§2.5).
_sqlite_uuid7() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import os, time
ms = int(time.time() * 1000) & ((1 << 48) - 1)
b = bytearray(os.urandom(16))
b[0] = (ms >> 40) & 0xFF; b[1] = (ms >> 32) & 0xFF
b[2] = (ms >> 24) & 0xFF; b[3] = (ms >> 16) & 0xFF
b[4] = (ms >> 8) & 0xFF;  b[5] = ms & 0xFF
b[6] = 0x70 | (b[6] & 0x0F)            # version 7
b[8] = 0x80 | (b[8] & 0x3F)            # variant 10
h = b.hex()
print(f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}")
PY
    return
  fi
  # Shell fallback: 48-bit ms hex from epoch + 80 random bits from urandom.
  local ms hex rnd
  ms=$(( $(date -u +%s) * 1000 ))
  hex=$(printf '%012x' "$ms")
  rnd=$(head -c 10 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s-%s-7%s-%s%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${rnd:0:3}" \
    "8" "${rnd:3:3}" "${rnd:6:12}"
}

_sqlite_db() { agmsg_db_path; }

# Build a SQL string literal (single-quote escaped) from $1.
_sqlite_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

# Build an "IN (...)" list of team||':'||agent pairs from "<team>:<agent>" args.
_sqlite_pair_in() {
  local out="" p t a
  for p in "$@"; do
    t="${p%%:*}"; a="${p#*:}"
    out="${out:+$out,}'$(_sqlite_lit "$t:$a")'"
  done
  printf '%s' "${out:-''}"
}

# --- contract: lifecycle ---------------------------------------------------

storage_check() {
  command -v sqlite3 >/dev/null 2>&1 || { echo "missing_deps: sqlite3 not found" >&2; return 3; }
  echo "ok"
}

storage_describe() {
  printf 'name=sqlite\n'
  printf 'backend=SQLite (WAL) event log + legacy messages table\n'
  printf 'db=%s\n' "$(_sqlite_db)"
}

storage_init() {
  local db; db="$(_sqlite_db)"
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  agmsg_sqlite "$db" "
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS events (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      type       TEXT NOT NULL,
      id         TEXT NOT NULL,
      team       TEXT,
      from_agent TEXT,
      to_agent   TEXT,
      body       TEXT,
      msg_id     TEXT,
      agent      TEXT,
      at         TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS events_sent ON events(type, team, to_agent, seq);
    CREATE INDEX IF NOT EXISTS events_read ON events(type, team, agent, msg_id);
  " >/dev/null 2>&1
}

# --- contract: messages ----------------------------------------------------

storage_send() {
  local team="$1" from="$2" to="$3" body="$4"
  local id at db; id="$(_sqlite_uuid7)"; at="$(_sqlite_now)"; db="$(_sqlite_db)"
  storage_init
  agmsg_sqlite "$db" "
    INSERT INTO events (type,id,team,from_agent,to_agent,body,at)
    VALUES ('message_sent','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
            '$(_sqlite_lit "$from")','$(_sqlite_lit "$to")','$(_sqlite_lit "$body")',
            '$(_sqlite_lit "$at")');
  " >/dev/null 2>&1 || return 1
  printf '%s\n' "$id"
}

# storage_list_unread <team> <agent> [--limit N]
storage_list_unread() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  local db; db="$(_sqlite_db)"
  local tl al; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  agmsg_sqlite "$db" "
    SELECT json_object('id',e.id,'team',e.team,'from',e.from_agent,
                       'to',e.to_agent,'body',e.body,'at',e.at)
    FROM events e
    WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
      AND NOT EXISTS (
        SELECT 1 FROM events r
        WHERE r.type='message_read' AND r.team=e.team
          AND r.agent='$al' AND r.msg_id=e.id)
    ORDER BY e.seq ASC ${limit:+LIMIT $limit};
  " 2>/dev/null | tr -d '\r'
}

# storage_mark_read_batch <team> <agent> <id> [<id> ...]
storage_mark_read_batch() {
  local team="$1" agent="$2"; shift 2
  [ $# -gt 0 ] || return 0
  local db at tl al; db="$(_sqlite_db)"; at="$(_sqlite_now)"
  tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  storage_init
  local id sql=""
  for id in "$@"; do
    local idl rid; idl="$(_sqlite_lit "$id")"; rid="$(_sqlite_uuid7)"
    # Idempotent: only insert a message_read if this recipient hasn't read it.
    sql="$sql
    INSERT INTO events (type,id,team,agent,msg_id,at)
    SELECT 'message_read','$(_sqlite_lit "$rid")','$tl','$al','$idl','$(_sqlite_lit "$at")'
    WHERE NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                      AND r.team='$tl' AND r.agent='$al' AND r.msg_id='$idl');"
  done
  agmsg_sqlite "$db" "$sql" >/dev/null 2>&1
}

# --- contract: delivery cursor ---------------------------------------------

# storage_watch_tip <team:agent> ... -> opaque cursor for "now"
storage_watch_tip() {
  local db; db="$(_sqlite_db)"
  storage_init
  agmsg_sqlite "$db" "SELECT COALESCE(MAX(seq),0) FROM events;" 2>/dev/null | tr -d '\r'
}

# storage_watch_after <cursor> <team:agent> ... -> JSONL message_sent + cursor record
storage_watch_after() {
  local cursor="$1"; shift
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  local db pairs; db="$(_sqlite_db)"; pairs="$(_sqlite_pair_in "$@")"
  agmsg_sqlite "$db" "
    SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                       'to',to_agent,'body',body,'at',at)
    FROM events
    WHERE type='message_sent' AND seq > $cursor
      AND (team || ':' || to_agent) IN ($pairs)
    ORDER BY seq ASC;
    SELECT json_object('type','cursor','cursor',
                       CAST(COALESCE(MAX(seq), $cursor) AS TEXT))
    FROM events;
  " 2>/dev/null | tr -d '\r'
}

# --- contract: history -----------------------------------------------------

# storage_history <team> <agent> [--limit N]
storage_history() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  local db tl al; db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  agmsg_sqlite "$db" "
    SELECT json_object('id',id,'team',team,'from',from_agent,'to',to_agent,
                       'body',body,'at',at)
    FROM events
    WHERE type='message_sent' AND team='$tl'
      AND (to_agent='$al' OR from_agent='$al')
    ORDER BY seq ASC ${limit:+LIMIT $limit};
  " 2>/dev/null | tr -d '\r'
}

# --- contract: export / import / compact -----------------------------------

storage_export() {
  local file="$1" db; db="$(_sqlite_db)"
  storage_init
  agmsg_sqlite "$db" "
    SELECT CASE type
      WHEN 'message_sent' THEN json_object('type','message_sent','id',id,'team',team,
             'from',from_agent,'to',to_agent,'body',body,'at',at)
      WHEN 'message_read' THEN json_object('type','message_read','id',id,'team',team,
             'agent',agent,'msg_id',msg_id,'at',at)
    END
    FROM events ORDER BY seq ASC;
  " 2>/dev/null | tr -d '\r' > "$file"
}

storage_import() {
  local file="$1" db; db="$(_sqlite_db)"
  [ -f "$file" ] || return 1
  storage_init
  local line t id team frm to body msg_id agent at
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t=$(printf '%s' "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
    j() { printf '%s' "$line" | sqlite3 :memory: "SELECT COALESCE(json_extract('$(_sqlite_lit "$line")','\$.$1'),'')" 2>/dev/null | tr -d '\r'; }
    id=$(j id); team=$(j team); at=$(j at)
    if [ "$t" = message_sent ]; then
      frm=$(j from); to=$(j to); body=$(j body)
      agmsg_sqlite "$db" "INSERT INTO events (type,id,team,from_agent,to_agent,body,at)
        VALUES ('message_sent','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
                '$(_sqlite_lit "$frm")','$(_sqlite_lit "$to")','$(_sqlite_lit "$body")',
                '$(_sqlite_lit "$at")');" >/dev/null 2>&1
    elif [ "$t" = message_read ]; then
      agent=$(j agent); msg_id=$(j msg_id)
      agmsg_sqlite "$db" "INSERT INTO events (type,id,team,agent,msg_id,at)
        VALUES ('message_read','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
                '$(_sqlite_lit "$agent")','$(_sqlite_lit "$msg_id")','$(_sqlite_lit "$at")');" \
        >/dev/null 2>&1
    fi
  done < "$file"
}

# Internal (§2.7): coalesce duplicate message_read markers, keeping the earliest.
storage_compact() {
  local db; db="$(_sqlite_db)"
  agmsg_sqlite "$db" "
    DELETE FROM events WHERE type='message_read' AND seq NOT IN (
      SELECT MIN(seq) FROM events WHERE type='message_read'
      GROUP BY team, agent, msg_id);
  " >/dev/null 2>&1
}
