#!/usr/bin/env bash
# jsonl storage driver (opt-in).
#
# Implements the storage contract (docs/spec/driver-interface.md §2, ADR 0003)
# over an append-only JSONL event log — the same canonical model as the sqlite
# driver (message_sent / message_read), but the file IS the store. Sourced by the
# storage facade (lib/storage.sh), so agmsg_db_path is in scope; the log lives at
# <db-dir>/events.jsonl.
#
# Engine: jq is the zero-extra-dep default (declared by storage_check). duckdb is
# an OPT-IN accelerator for the one hot anti-join (list_unread) on large logs —
# the PoC crossover is ~10-20k events (#207 / FINDINGS.md); below it jq's lack of
# startup cost wins, so the driver picks jq unless the log is big AND duckdb is on
# PATH. No daemon: duckdb runs file-direct, one process per query.
#
# Framing (§1.4): record-returning ops write JSONL to stdout and fail non-zero;
# control ops (check/init/mark_read_batch/compact) print a §1.4 status name.
#
# Delivery cursor (§2.2): a LOGICAL position — the ordinal count of message_sent
# events, NOT a byte offset. Compaction only coalesces message_read (never removes
# or reorders message_sent), so an ordinal stays valid across a log rewrite; a
# byte offset would not. The cursor is an opaque decimal string to core.

# --- helpers ---------------------------------------------------------------

_jsonl_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_jsonl_log() { printf '%s\n' "$(dirname "$(agmsg_db_path)")/events.jsonl"; }

_jsonl_init_file() {
  local log; log="$(_jsonl_log)"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  [ -f "$log" ] || : > "$log" 2>/dev/null || true
}

# UUIDv7 (§2.5) — python3 preferred, /dev/urandom shell fallback. No counter file.
_jsonl_uuid7() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import os, time
ms = int(time.time() * 1000) & ((1 << 48) - 1)
b = bytearray(os.urandom(16))
b[0] = (ms >> 40) & 0xFF; b[1] = (ms >> 32) & 0xFF
b[2] = (ms >> 24) & 0xFF; b[3] = (ms >> 16) & 0xFF
b[4] = (ms >> 8) & 0xFF;  b[5] = ms & 0xFF
b[6] = 0x70 | (b[6] & 0x0F)
b[8] = 0x80 | (b[8] & 0x3F)
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

# Serialize all log mutations (append / mark / compact / import) behind a portable
# mkdir lock; record-returning reads take a single file read as their snapshot.
_jsonl_with_lock() {
  local lock i=0 rc=0 max="${AGMSG_JSONL_LOCK_TRIES:-1000}"
  lock="$(_jsonl_log).lock"
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -ge "$max" ] && return 1
    sleep 0.01
  done
  "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return $rc
}

# duckdb is used only when present AND the log is past the jq crossover. The check
# is byte-size based (file-direct I/O is size-bound, FINDINGS.md): ~5 MB ≈ tens of
# thousands of events. AGMSG_JSONL_ENGINE=jq|duckdb forces a choice (tests/bench).
_jsonl_use_duckdb() {
  case "${AGMSG_JSONL_ENGINE:-}" in
    jq) return 1 ;;
    duckdb) command -v duckdb >/dev/null 2>&1 && return 0 || return 1 ;;
  esac
  command -v duckdb >/dev/null 2>&1 || return 1
  local log sz; log="$(_jsonl_log)"
  sz=$(wc -c < "$log" 2>/dev/null | tr -d ' ') || return 1
  [ "${sz:-0}" -ge "${AGMSG_JSONL_DUCKDB_BYTES:-5242880}" ]
}

# --- contract: lifecycle ----------------------------------------------------

storage_check() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'AGMSG-DIRECTIVE: {"type":"install_deps","driver":"jsonl","commands":["brew install jq"],"reason":"jq not found on PATH"}\n'
    echo missing_deps
    return 10
  fi
  echo ok
}

storage_describe() {
  printf 'name=jsonl\n'
  printf 'backend=append-only JSONL event log (jq; duckdb opt-in accelerator)\n'
  printf 'log=%s\n' "$(_jsonl_log)"
}

storage_init() {
  _jsonl_init_file
  echo ok
}

# Does a store already exist? (does NOT create one.) The log is the store, so a
# read call-site can answer "no messages yet" without lazily creating events.jsonl.
storage_store_exists() { [ -f "$(_jsonl_log)" ]; }

# --- contract: messages -----------------------------------------------------

storage_send() {
  local team="$1" from="$2" to="$3" body="$4"
  local id at line; id="$(_jsonl_uuid7)"; at="$(_jsonl_now)"
  _jsonl_init_file
  line="$(jq -nc --arg id "$id" --arg team "$team" --arg from "$from" \
    --arg to "$to" --arg body "$body" --arg at "$at" \
    '{type:"message_sent",id:$id,team:$team,from:$from,to:$to,body:$body,at:$at}')" \
    || return 1
  _jsonl_with_lock _jsonl_append "$line" || return 1
  printf '%s\n' "$id"
}
_jsonl_append() { printf '%s\n' "$1" >> "$(_jsonl_log)"; }

storage_list_unread() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  _jsonl_init_file
  local log out; log="$(_jsonl_log)"
  if _jsonl_use_duckdb; then
    out="$(_jsonl_unread_duckdb "$team" "$agent" "$log")" || return 1
  else
    out="$(jq -c --arg team "$team" --arg agent "$agent" -s '
      (reduce .[] as $e ({};
        if $e.type=="message_read" and $e.team==$team and $e.agent==$agent
        then .[$e.msg_id]=true else . end)) as $read
      | .[]
      | select(.type=="message_sent" and .team==$team and .to==$agent and ($read[.id] | not))
      | {type:"message_sent",id:.id,team:.team,from:.from,to:.to,body:.body,at:.at}
    ' "$log")" || return 1
  fi
  [ -n "$out" ] || return 0
  if [ -n "$limit" ]; then printf '%s\n' "$out" | head -n "$limit"; else printf '%s\n' "$out"; fi
}

# duckdb file-direct anti-join (opt-in, large logs). Same unread set AND identical
# record shape as the jq path. Fields are read as explicit VARCHAR columns — never
# read_json_auto, whose type inference would parse `at` as a TIMESTAMP and re-emit
# it as "Y-M-D H:M:S", losing the canonical ISO-8601 "...T...Z" the jq path keeps.
_jsonl_unread_duckdb() {
  local team="$1" agent="$2" log="$3"
  # SQL-escape every value spliced into the query (team/agent are not apostrophe-
  # free per validate.sh, and the path may contain one) so a legal team/agent that
  # the jq path handles can't break — or silently misbehave on — the duckdb path.
  local tl al lg
  tl="$(printf '%s' "$team"  | sed "s/'/''/g")"
  al="$(printf '%s' "$agent" | sed "s/'/''/g")"
  lg="$(printf '%s' "$log"   | sed "s/'/''/g")"
  local cols="columns={type:'VARCHAR', id:'VARCHAR', team:'VARCHAR', \"from\":'VARCHAR', \"to\":'VARCHAR', body:'VARCHAR', at:'VARCHAR', msg_id:'VARCHAR', agent:'VARCHAR'}, format='newline_delimited'"
  duckdb -noheader -list -newline $'\n' <<SQL 2>/dev/null
SELECT to_json(struct_pack(type := 'message_sent', id := s.id, team := s.team,
         "from" := s."from", "to" := s."to", body := s.body, at := s.at))
FROM (SELECT * FROM read_json('$lg', $cols) WHERE type='message_sent'
        AND team='$tl' AND "to"='$al') s
WHERE s.id NOT IN (
  SELECT msg_id FROM read_json('$lg', $cols)
  WHERE type='message_read' AND team='$tl' AND agent='$al')
ORDER BY s.at, s.id;
SQL
}

storage_mark_read_batch() {
  local team="$1" agent="$2"; shift 2
  _jsonl_init_file
  # Propagate a lock-acquire / write failure as a §1.4 control-op error — never
  # swallow it as ok, or inbox/check-inbox would treat unread as read with no
  # message_read written (re-delivery loop / stale wake on the read hot path).
  _jsonl_with_lock _jsonl_mark "$team" "$agent" "$@" || { echo runtime_error; return 13; }
  echo ok
}
_jsonl_mark() {
  local team="$1" agent="$2"; shift 2
  local log id at line existing; log="$(_jsonl_log)"
  # A failed scan of existing reads (e.g. a corrupt log) must abort the mark, not
  # silently treat every id as new and append — that would be the same swallowed
  # failure. The caller turns this non-zero into runtime_error.
  existing="$(jq -r --arg team "$team" --arg agent "$agent" \
    'select(.type=="message_read" and .team==$team and .agent==$agent) | .msg_id' \
    "$log")" || return 1
  for id in "$@"; do
    printf '%s\n' "$existing" | grep -Fxq "$id" && continue
    at="$(_jsonl_now)"
    line="$(jq -nc --arg id "$(_jsonl_uuid7)" --arg msg_id "$id" --arg team "$team" \
      --arg agent "$agent" --arg at "$at" \
      '{type:"message_read",id:$id,msg_id:$msg_id,team:$team,agent:$agent,at:$at}')"
    printf '%s\n' "$line" >> "$log"
    existing="$existing"$'\n'"$id"
  done
}

# --- contract: watch (delivery cursor §2.2) ---------------------------------

storage_watch_tip() {
  _jsonl_init_file
  # An empty log makes jq return 0 with exit 0; a CORRUPT log makes jq fail, and
  # that must surface as a non-zero exit (data-op framing §2.1) — no `|| echo 0`
  # fallback that would mask a broken store as a fresh tip of 0.
  jq -s '[.[] | select(.type=="message_sent")] | length' "$(_jsonl_log)"
}

storage_watch_after() {
  local cursor="$1"; shift
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  _jsonl_init_file
  local pairs_json; pairs_json="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length>0))')"
  # One file read = one snapshot: the trailing cursor (total message_sent count)
  # is computed from the same scan, so it never runs ahead of the rows returned.
  jq -c --argjson cursor "$cursor" --argjson pairs "$pairs_json" -s '
    [.[] | select(.type=="message_sent")] as $sent
    | ($sent
        | to_entries
        | map(select((.key >= $cursor)
              and ((.value.team + ":" + .value.to) as $p | ($pairs | index($p)) != null)))
        | .[].value
        | {type:"message_sent",id:.id,team:.team,from:.from,to:.to,body:.body,at:.at}),
      {type:"cursor",cursor:(($sent | length) | tostring)}
  ' "$(_jsonl_log)" 2>/dev/null
}

# --- contract: history ------------------------------------------------------

storage_history() {
  local team="$1"; shift
  local agent="" limit=""
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then agent="$1"; shift; fi
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="-1" ;; esac
  _jsonl_init_file
  jq -c --arg team "$team" --arg agent "$agent" --argjson limit "$limit" -s '
    [.[] | select(.type=="message_sent" and .team==$team
            and ($agent=="" or .to==$agent or .from==$agent))
     | {type:"message_sent",id:.id,team:.team,from:.from,to:.to,body:.body,at:.at}]
    | (if $limit >= 0 and (length > $limit) then .[length-$limit:] else . end)
    | .[]
  ' "$(_jsonl_log)" 2>/dev/null
}

# --- contract: export / import / compact ------------------------------------

storage_export() {
  _jsonl_init_file
  # Forward-compat (§2.3): only the v1 event types are projected; unknown types
  # are dropped rather than leaked.
  jq -c 'select(.type=="message_sent" or .type=="message_read")' "$(_jsonl_log)" > "$1"
}

storage_import() {
  local file="$1"; [ -f "$file" ] || return 1
  _jsonl_init_file
  _jsonl_with_lock _jsonl_import_do "$file"
}
_jsonl_import_do() {
  jq -c 'select(.type=="message_sent" or .type=="message_read")' "$1" >> "$(_jsonl_log)"
}

storage_compact() {
  _jsonl_init_file
  _jsonl_with_lock _jsonl_compact_do || { echo runtime_error; return 13; }
  echo ok
}
_jsonl_compact_do() {
  local log tmp; log="$(_jsonl_log)"; tmp="$log.compact.$$"
  # Keep every message_sent in order; collapse duplicate message_read for the same
  # (team, agent, msg_id) to the first seen. message_sent order is preserved, so
  # the ordinal delivery cursor stays valid (§2.7 cursor-safe).
  jq -c -s '
    reduce .[] as $e ({out:[], seen:{}};
      if $e.type=="message_sent" then .out += [$e]
      elif $e.type=="message_read" then
        ($e.team + " " + $e.agent + " " + $e.msg_id) as $k
        | if .seen[$k] then . else .seen[$k]=true | .out += [$e] end
      else . end)
    | .out[]
  ' "$log" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$log"
}
