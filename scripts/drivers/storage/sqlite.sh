#!/usr/bin/env bash
# sqlite storage driver (built-in, default).
#
# Implements the storage contract (docs/spec/driver-interface.md §2, ADR 0003)
# over SQLite. Sourced by the storage facade (lib/storage.sh, agmsg_storage_load),
# so agmsg_db_path / agmsg_sqlite / agmsg_sql_readfile_path from storage.sh are in
# scope. State is an append-only `events` log (canonical JSONL: message_sent /
# message_read). The legacy `messages` table is read **read-only** and UNIONed
# into list_unread / history so an existing store keeps its inbox and history
# after #206 switches call sites onto the contract (§2.4); legacy rows are never
# migrated or mutated here.
#
# Framing (§1.4 / ADR 0003): record-returning ops write data only to stdout and
# fail with a non-zero exit; control ops (check/init/mark_read_batch/compact)
# print a §1.4 status name on stdout. The delivery cursor (§2.2) is the events.seq
# autoincrement, returned as an opaque decimal string. Read-marking is
# recipient-scoped ((team, agent)) and idempotent.

# --- helpers ---------------------------------------------------------------

_sqlite_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_sqlite_db() { agmsg_db_path; }
_sqlite_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

# Run a record-returning query: strip CR but PRESERVE the sqlite exit status
# (pipefail), so a backend failure surfaces as a non-zero return instead of
# being swallowed by tr's exit 0. The backend's error text goes to stderr (a
# separate fd — it never pollutes the JSONL on stdout) so failures are
# debuggable, per §2.1 framing (#203 (1) / co1 review).
_sqlite_data() {
  ( set -o pipefail; agmsg_sqlite "$(_sqlite_db)" "$1" | tr -d '\r' )
}

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
  local ms hex rnd
  ms=$(( $(date -u +%s) * 1000 ))
  hex=$(printf '%012x' "$ms")
  rnd=$(head -c 10 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s-%s-7%s-8%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${rnd:0:3}" "${rnd:3:3}" "${rnd:6:12}"
}

# IN (...) list of "team:agent" pairs.
_sqlite_pair_in() {
  local out="" p t a
  for p in "$@"; do
    t="${p%%:*}"; a="${p#*:}"
    out="${out:+$out,}'$(_sqlite_lit "$t:$a")'"
  done
  printf '%s' "${out:-''}"
}

# --- contract: lifecycle (control ops, §1.4 status on stdout) ---------------

storage_check() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo missing_deps
    return 10
  fi
  echo ok
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
    -- Legacy store (read-only here). Created so the UNION queries always parse
    -- even on a brand-new install with no pre-event-log data.
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      team TEXT NOT NULL,
      from_agent TEXT NOT NULL,
      to_agent TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      read_at TEXT
    );
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# --- contract: messages ----------------------------------------------------

storage_send() {
  local team="$1" from="$2" to="$3" body="$4"
  local id at db; id="$(_sqlite_uuid7)"; at="$(_sqlite_now)"; db="$(_sqlite_db)"
  storage_init >/dev/null
  agmsg_sqlite "$db" "
    INSERT INTO events (type,id,team,from_agent,to_agent,body,at)
    VALUES ('message_sent','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
            '$(_sqlite_lit "$from")','$(_sqlite_lit "$to")','$(_sqlite_lit "$body")',
            '$(_sqlite_lit "$at")');
  " >/dev/null 2>&1 || return 1
  printf '%s\n' "$id"
}

# storage_list_unread <team> <agent> [--limit N]
# events-unread ∪ legacy-unread (read_at IS NULL, not superseded by a read event).
storage_list_unread() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init >/dev/null
  local tl al; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  _sqlite_data "
    SELECT j FROM (
      SELECT json_object('type','message_sent','id',e.id,'team',e.team,
               'from',e.from_agent,'to',e.to_agent,'body',e.body,'at',e.at) AS j,
             e.at AS ts, 1 AS src, e.seq AS ord
      FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=e.team AND r.agent='$al' AND r.msg_id=e.id)
      UNION ALL
      SELECT json_object('type','message_sent','id',CAST(m.id AS TEXT),'team',m.team,
               'from',m.from_agent,'to',m.to_agent,'body',m.body,'at',m.created_at) AS j,
             m.created_at AS ts, 0 AS src, m.id AS ord
      FROM messages m
      WHERE m.team='$tl' AND m.to_agent='$al' AND m.read_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=m.team AND r.agent='$al' AND r.msg_id=CAST(m.id AS TEXT))
    )
    ORDER BY ts, src, ord ${limit:+LIMIT $limit};
  "
}

# storage_mark_read_batch <team> <agent> <id> [<id> ...]  (control op)
storage_mark_read_batch() {
  local team="$1" agent="$2"; shift 2
  [ $# -gt 0 ] || { echo ok; return 0; }
  local db at tl al; db="$(_sqlite_db)"; at="$(_sqlite_now)"
  tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  storage_init >/dev/null
  local id sql=""
  for id in "$@"; do
    local idl rid; idl="$(_sqlite_lit "$id")"; rid="$(_sqlite_uuid7)"
    sql="$sql
    INSERT INTO events (type,id,team,agent,msg_id,at)
    SELECT 'message_read','$(_sqlite_lit "$rid")','$tl','$al','$idl','$(_sqlite_lit "$at")'
    WHERE NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                      AND r.team='$tl' AND r.agent='$al' AND r.msg_id='$idl');"
  done
  agmsg_sqlite "$db" "$sql" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# --- contract: delivery cursor ---------------------------------------------

# The delivery tip is the monotonic AUTOINCREMENT high-water (largest rowid ever
# assigned to `events`), read from sqlite_sequence — NOT MAX(seq) over live rows.
# A DELETE-based storage_compact can lower MAX(seq) (e.g. by coalescing the
# tail message_read) but never the high-water, so a cursor issued before a
# compaction stays valid and a fresh tip never moves backwards (§2.7 cursor-safe).
_sqlite_highwater() {
  printf "COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)"
}

storage_watch_tip() {
  storage_init >/dev/null
  _sqlite_data "SELECT $(_sqlite_highwater);"
}

storage_watch_after() {
  local cursor="$1"; shift
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  local pairs; pairs="$(_sqlite_pair_in "$@")"
  _sqlite_data "
    SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                       'to',to_agent,'body',body,'at',at)
    FROM events
    WHERE type='message_sent' AND seq > $cursor
      AND (team || ':' || to_agent) IN ($pairs)
    ORDER BY seq ASC;
    SELECT json_object('type','cursor','cursor',
                       CAST(MAX($cursor, $(_sqlite_highwater)) AS TEXT));
  "
}

# --- contract: history -----------------------------------------------------

# storage_history <team> <agent> [--limit N]  — events ∪ legacy, agent involved.
storage_history() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init >/dev/null
  local tl al; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  _sqlite_data "
    SELECT j FROM (
      SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
               'to',to_agent,'body',body,'at',at) AS j, at AS ts, 1 AS src, seq AS ord
      FROM events
      WHERE type='message_sent' AND team='$tl' AND (to_agent='$al' OR from_agent='$al')
      UNION ALL
      SELECT json_object('type','message_sent','id',CAST(id AS TEXT),'team',team,
               'from',from_agent,'to',to_agent,'body',body,'at',created_at) AS j,
             created_at AS ts, 0 AS src, id AS ord
      FROM messages
      WHERE team='$tl' AND (to_agent='$al' OR from_agent='$al')
    )
    ORDER BY ts, src, ord ${limit:+LIMIT $limit};
  "
}

# --- contract: export / import / compact -----------------------------------

storage_export() {
  local file="$1"
  storage_init >/dev/null
  # Forward-compat (§2.3): only the v1 event types are projected. A WHERE filter
  # (not just a CASE) keeps unknown-type rows out entirely, so they never surface
  # as a NULL → blank line on stdout, matching list_unread/history/watch_after.
  _sqlite_data "
    SELECT CASE type
      WHEN 'message_sent' THEN json_object('type','message_sent','id',id,'team',team,
             'from',from_agent,'to',to_agent,'body',body,'at',at)
      WHEN 'message_read' THEN json_object('type','message_read','id',id,'team',team,
             'agent',agent,'msg_id',msg_id,'at',at)
    END
    FROM events
    WHERE type IN ('message_sent','message_read')
    ORDER BY seq ASC;
  " > "$file"
}

storage_import() {
  local file="$1" db; db="$(_sqlite_db)"
  [ -f "$file" ] || return 1
  storage_init >/dev/null
  local line t id team frm to body msg_id agent at
  j() { sqlite3 :memory: "SELECT COALESCE(json_extract('$(_sqlite_lit "$line")','\$.$1'),'')" 2>/dev/null | tr -d '\r'; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t=$(j type); id=$(j id); team=$(j team); at=$(j at)
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

# Internal (§2.7): coalesce duplicate message_read markers, keeping the earliest. (control op)
storage_compact() {
  local db; db="$(_sqlite_db)"
  agmsg_sqlite "$db" "
    DELETE FROM events WHERE type='message_read' AND seq NOT IN (
      SELECT MIN(seq) FROM events WHERE type='message_read'
      GROUP BY team, agent, msg_id);
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}
