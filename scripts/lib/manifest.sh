#!/usr/bin/env bash
# manifest.sh — append-only ledger of delivery-role artifacts agmsg creates.
#
# Background (orangewk/agmsg#8): agmsg has many entry points that spin up a
# delivery role — a watcher process, a codex bridge, a shared codex
# app-server, a pidfile, and (outside this repo's direct control) Windows
# Scheduled Tasks / Codex automations / ad-hoc state files. Each entry point
# has its own idea of who tears the thing down (trap, session-end, `set off`,
# manual). When a teardown path is skipped — hard kill, PC restart, a hook
# that never fires — nothing else knows the artifact ever existed, so nothing
# ever reaps it.
#
# This file gives every "operation that spawns a delivery role" one place to
# record that fact: a single append-only ledger,
#   $SKILL_DIR/run/manifest.jsonl
# One JSON object per line, one line per lifecycle event. Never rewritten in
# place — disposal is recorded as a NEW line, not an edit of the create line,
# so concurrent writers (multiple sessions/processes) only ever need O_APPEND
# semantics, not locking.
#
# Line shapes (all fields are plain strings; no nested arrays):
#
#   create event:
#     {"ts":"<ISO8601>","event":"create","kind":"<kind>","id":{...},
#      "createdBy":"<owner token, e.g. instance id or cc pid>",
#      "disposeHint":"<free-text hint for a human or gc>"}
#
#   dispose event:
#     {"ts":"<ISO8601>","event":"dispose","kind":"<kind>","id":{...},
#      "disposedBy":"<'gc'|'manual'|caller-supplied token>"}
#
# `kind` values in use and their `id` shape:
#   process          {"pid":"<msys pid>","pidSpace":"msys","cmdline":"<argv>","startedAt":"<ISO8601>"}
#   pidfile           {"path":"<abs path>"}
#   scheduled-task    {"taskName":"<schtasks name>"}
#   automation        {"automationId":"<id>"}
#   state-file        {"path":"<abs path>"}
#
# PID SPACE DECISION — two spaces coexist and BOTH are real (verified
# empirically while building this file; see WP1 report for the repro):
#
#   "msys"   — the pid as bash's own job control sees it (`$!`, `$$`). `kill -0`
#              and compat_get_cmdline (compat.sh) work directly on this space.
#              This is what every bash-launched child (watch.sh, spawn.sh boot
#              scripts, the codex app-server bash launched via `&`) reports.
#
#   "native" — the Windows-native pid as the OS (and CIM/tasklist) sees it.
#              `kill -0` on a native pid FAILS ("No such process") even though
#              the process is alive — confirmed by direct test: backgrounding
#              `node -e "console.log(process.pid)"` and comparing bash's `$!`
#              against the pid Node itself printed shows two DIFFERENT numbers
#              (nohup backgrounds a bash subshell, not the exec'd binary,
#              whenever the command isn't `exec`'d — `codex-bridge-launcher.sh`
#              backgrounds `nohup node ... &`, so `$!` there is the subshell,
#              not Node). Node's own `process.pid` (what codex-bridge.js's
#              writeMeta() writes to its pidfile) is a NATIVE pid. Liveness for
#              a native pid must use tasklist (see instance-id.sh's
#              _agmsg_pid_alive, already established for the Claude Code agent
#              pid) and cmdline lookup must use CIM directly by that pid (see
#              compat_get_native_cmdline in compat.sh) — NOT compat_get_cmdline,
#              which expects an MSYS pid and translates msys->winpid internally.
#
# Every "process" id therefore carries an explicit `"pidSpace":"msys"|"native"`
# so a reader never has to guess or re-derive which liveness/cmdline path
# applies — get it wrong and you silently reap a live process (msys check on a
# native pid → false "dead") or never reap a truly dead one (native check
# skipped because everything looked like msys).
#
# PID REUSE: a bare pid is not sufficient identity — Windows recycles pids
# aggressively. Every "process" id therefore also carries `cmdline` (the full
# command line at creation time) and `startedAt`. A liveness/ownership check
# must re-fetch the CURRENT cmdline for that pid and compare against the
# recorded one (see manifest_process_is_same in this file) before treating a
# live pid as "the thing we created" — never trust a bare pid match alone.
#
# Required caller-set variable: SKILL_DIR (agmsg skill root; run/ hangs off it).

: "${SKILL_DIR:?manifest.sh requires SKILL_DIR}"

_manifest_path() { printf '%s/run/manifest.jsonl' "$SKILL_DIR"; }

# ISO8601 UTC timestamp, second resolution. Every platform bash here ships
# GNU or BSD date; both support -u -Iseconds-equivalent via +%Y-%m-%dT%H:%M:%SZ.
_manifest_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Minimal JSON string escaper: backslash and double-quote (the only bytes
# that appear in our values — paths, cmdlines, ids) plus control chars that
# would otherwise break the single-line jsonl invariant.
_manifest_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r' | tr '\n' ' '
}

# Normalize a RAW cmdline (as freshly returned by compat_get_cmdline /
# compat_get_native_cmdline) the same way a cmdline is normalized before it
# is written into the manifest (see manifest_process_id, which stores values
# through _manifest_json_escape — collapsing embedded newlines to spaces).
# Without this, a re-fetched cmdline containing a literal newline (a process
# whose argv has one, e.g. a bash -c "<multi-line script>" invocation) would
# never string-equal the manifest's already-collapsed copy, and
# manifest_process_is_same would wrongly report "not confirmed" for a pid
# that IS in fact the same, live process. Confirmed by direct repro while
# building this file's test suite. Not full JSON-escaping — just the
# structural (newline) normalization needed for a stable identity compare;
# _manifest_json_escape's quote/backslash escaping is for on-disk encoding,
# irrelevant to this equality check.
_manifest_normalize_cmdline() {
  printf '%s' "$1" | tr -d '\r' | tr '\n' ' '
}

# Append one create-event line. Never fails the caller's flow: manifest
# writes are best-effort hygiene, not correctness-critical (mirrors the
# advisory tone of the existing watermark/ready-sentinel GC in
# session-start.sh). A missing manifest write means "gc.sh won't reap this if
# it's later abandoned" — degraded observability, not a broken feature.
#
# Usage: manifest_record_create <kind> <id-json-object> <createdBy> [disposeHint]
#   <id-json-object> is a pre-built JSON object string, e.g.:
#     $(manifest_process_id "$pid" "$cmdline" "$started_at")
manifest_record_create() {
  local kind="$1" id_json="$2" created_by="$3" hint="${4:-}"
  local dir; dir="$SKILL_DIR/run"
  mkdir -p "$dir" 2>/dev/null || return 0
  {
    printf '{"ts":"%s","event":"create","kind":"%s","id":%s,"createdBy":"%s","disposeHint":"%s"}\n' \
      "$(_manifest_now)" \
      "$(_manifest_json_escape "$kind")" \
      "$id_json" \
      "$(_manifest_json_escape "$created_by")" \
      "$(_manifest_json_escape "$hint")"
  } >> "$(_manifest_path)" 2>/dev/null || true
}

# Append one dispose-event line. Same best-effort contract as
# manifest_record_create.
#
# Usage: manifest_record_dispose <kind> <id-json-object> <disposedBy>
manifest_record_dispose() {
  local kind="$1" id_json="$2" disposed_by="$3"
  local dir; dir="$SKILL_DIR/run"
  mkdir -p "$dir" 2>/dev/null || return 0
  {
    printf '{"ts":"%s","event":"dispose","kind":"%s","id":%s,"disposedBy":"%s"}\n' \
      "$(_manifest_now)" \
      "$(_manifest_json_escape "$kind")" \
      "$id_json" \
      "$(_manifest_json_escape "$disposed_by")"
  } >> "$(_manifest_path)" 2>/dev/null || true
}

# Build the `id` JSON object for a kind=process entry.
# Usage: manifest_process_id <pid> <cmdline> <startedAt> [pidSpace=msys]
# pidSpace defaults to "msys" (the common case: a bash-launched child, checked
# via kill -0 / compat_get_cmdline). Pass "native" explicitly for a pid that is
# only knowable in Windows-native space (e.g. Node reporting its own
# process.pid from inside a `nohup ... &` — see the PID SPACE DECISION comment
# above); such an id must be checked with instance-id.sh's _agmsg_pid_alive +
# compat.sh's compat_get_native_cmdline, never kill -0/compat_get_cmdline.
manifest_process_id() {
  local pid="$1" cmdline="$2" started_at="$3" pid_space="${4:-msys}"
  printf '{"pid":"%s","pidSpace":"%s","cmdline":"%s","startedAt":"%s"}' \
    "$(_manifest_json_escape "$pid")" \
    "$(_manifest_json_escape "$pid_space")" \
    "$(_manifest_json_escape "$cmdline")" \
    "$(_manifest_json_escape "$started_at")"
}

# Build the `id` JSON object for a kind=pidfile entry.
manifest_pidfile_id() {
  printf '{"path":"%s"}' "$(_manifest_json_escape "$1")"
}

# Build the `id` JSON object for a kind=state-file entry.
manifest_state_file_id() {
  printf '{"path":"%s"}' "$(_manifest_json_escape "$1")"
}

# Extract a top-level string field's value from one jsonl line, without a
# JSON parser dependency (agmsg has none; jq is not assumed installed — see
# hash.sh's own tool-availability fallback pattern). Only handles the flat
# `"field":"value"` shape this file emits; not a general JSON parser.
#
# A naive `sed 's/.../"\([^"]*\)"/p'` (this file's first cut) BREAKS on any
# value containing an escaped quote — e.g. a recorded cmdline like
# `bash -c "some script"` is JSON-escaped to `bash -c \"some script\"`, and
# `[^"]*` stops at the first *literal* `"` byte, truncating the match right
# there. Confirmed by direct repro while building this file's test suite (a
# live process's own re-fetched cmdline, once JSON-round-tripped, silently
# stopped matching its stored copy — manifest_process_is_same then failed
# closed and a live process was wrongly treated as gone). Character-scanning
# in awk correctly walks PAST an escaped `\"` (and `\\`) to find the true
# closing quote.
_manifest_json_field_value() {
  local json="$1" field="$2"
  printf '%s' "$json" | awk -v field="$field" '
    {
      key = "\"" field "\":\""
      pos = index($0, key)
      if (pos == 0) { next }
      i = pos + length(key)
      out = ""
      n = length($0)
      while (i <= n) {
        c = substr($0, i, 1)
        if (c == "\\") {
          out = out c substr($0, i + 1, 1)
          i += 2
          continue
        }
        if (c == "\"") { break }
        out = out c
        i += 1
      }
      print out
      exit
    }
  '
}

# Extract a top-level string field's value from one jsonl line.
_manifest_field() {
  _manifest_json_field_value "$1" "$2"
}

# Extract a field nested one level inside the `id` object, e.g. pid/path.
# Reuses the same scanner: since every field name this file emits is unique
# within a line (no top-level field shares a name with an id field), scanning
# the whole line for "<field>":"..." finds the id-nested one correctly without
# needing to first isolate the `id:{...}` substring.
_manifest_id_field() {
  _manifest_json_field_value "$1" "$2"
}

# Re-fetch a pid's current cmdline and compare it against a manifest-recorded
# cmdline. Returns 0 (same process) only on a non-empty match — an empty
# current cmdline (pid dead, or cmdline unreadable) is never treated as a
# match, so a transient lookup failure fails closed (treated as "not
# confirmed", which callers should treat as "don't touch it"), not as a false
# positive kill target. Dispatches to the msys or native cmdline lookup per
# pidSpace (see the PID SPACE DECISION comment above) — using the wrong one
# silently returns empty (msys lookup on a native-only pid, or vice versa),
# which this function's fail-closed behavior turns into "not the same", not a
# crash. That is the safe direction to fail in.
#
# IMPORTANT: <recorded_cmdline> must be the value AS STORED in the manifest —
# i.e. already JSON-escaped (what manifest_open_processes / _manifest_id_field
# hand back, or what manifest_process_id itself would embed). This function
# escapes the freshly-fetched `current` cmdline the same way before comparing,
# so both sides go through identical normalization. Comparing a raw fetch
# against an escaped-at-write-time value without this step silently mismatches
# any cmdline containing a literal `"` (very common — quoted args are
# everywhere), which fails closed to "not the same" and would misclassify a
# genuinely live, unchanged process as gone. Caught by this WP's own test
# suite (a `bash -c "<script with quotes>"` process failed this exact check
# before the escape-before-compare fix landed).
#
# Usage: manifest_process_is_same <pid> <recorded_cmdline> [pidSpace=msys]
manifest_process_is_same() {
  local pid="$1" recorded="$2" pid_space="${3:-msys}" current
  [ -n "$recorded" ] || return 1
  if [ "$pid_space" = "native" ]; then
    current="$(compat_get_native_cmdline "$pid" 2>/dev/null || true)"
  else
    current="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  fi
  [ -n "$current" ] || return 1
  current="$(_manifest_normalize_cmdline "$current")"
  current="$(_manifest_json_escape "$current")"
  [ "$current" = "$recorded" ]
}

# Scan the manifest and print, one per line, the fields of every kind=process
# create-event that has NOT since been followed by a kind=process
# dispose-event carrying the same pid. Best-effort: a manifest with
# unknown/malformed lines is tolerated (forward-compat with future kinds — an
# unparseable line is skipped, not fatal).
#
# Prints: <pid><TAB><cmdline><TAB><startedAt><TAB><pidSpace>
#
# This does NOT check liveness — callers (gc.sh) decide what "still open" plus
# "actually dead" means for their kind, dispatching on the trailing pidSpace
# field to pick kill -0/compat_get_cmdline (msys) vs _agmsg_pid_alive/
# compat_get_native_cmdline (native).
manifest_open_processes() {
  local path; path="$(_manifest_path)"
  [ -f "$path" ] || return 0
  local disposed_pids created_line pid cmdline started_at pid_space
  disposed_pids="$(awk -F'"event":"dispose"' 'NF>1' "$path" 2>/dev/null \
    | grep -o '"kind":"process"[^}]*"pid":"[^"]*"' \
    | sed -n 's/.*"pid":"\([^"]*\)".*/\1/p' || true)"
  while IFS= read -r created_line; do
    [ -n "$created_line" ] || continue
    case "$created_line" in *'"kind":"process"'*) ;; *) continue ;; esac
    pid="$(_manifest_id_field "$created_line" pid)"
    [ -n "$pid" ] || continue
    if printf '%s\n' "$disposed_pids" | grep -Fxq "$pid"; then
      continue
    fi
    cmdline="$(_manifest_id_field "$created_line" cmdline)"
    started_at="$(_manifest_id_field "$created_line" startedAt)"
    pid_space="$(_manifest_id_field "$created_line" pidSpace)"
    [ -n "$pid_space" ] || pid_space="msys"
    printf '%s\t%s\t%s\t%s\n' "$pid" "$cmdline" "$started_at" "$pid_space"
  done < <(grep '"event":"create"' "$path" 2>/dev/null)
}
