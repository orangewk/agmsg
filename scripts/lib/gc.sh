#!/usr/bin/env bash
# gc.sh — reap-on-startup garbage collection for delivery-role artifacts.
#
# Background (orangewk/agmsg#8): session-start.sh already runs a
# reap-on-startup pass for the watch.sh family (dead cc-instance records,
# orphan watcher pids, stale watermarks/ready sentinels) — see the inline
# block in session-start.sh. That pass never looks at the codex bridge /
# codex app-server artifacts (codex-bridge.<team>.<name>.{pid,meta,log,
# appserver}, codex-app-server.<hash>.{pid,port,log,version}), which are only
# ever cleaned up by `delivery.sh set off codex` (stop_codex_bridge) — a path
# the user has to remember to invoke. A hard kill, PC restart, or a session
# that never runs `set off` leaves those files behind forever (this is
# exactly what issue #8 found: dead pids with live-looking pidfiles, armed
# bridge logs, no reaper).
#
# This file adds that missing half, following the SAME house style as the
# existing session-start.sh block: read a candidate file, confirm the
# recorded pid is actually dead (or, if alive, confirm via cmdline that it's
# really OUR process before touching it — never trust a bare pid alone,
# Windows recycles pids aggressively), then remove.
#
# Required caller-set variable: SKILL_DIR (agmsg skill root; run/ hangs off it).
# Callers must also have sourced, before calling into this file:
#   lib/compat.sh        — compat_get_cmdline, compat_get_native_cmdline
#   lib/instance-id.sh   — _agmsg_pid_alive (native-pid liveness via tasklist)
#   lib/manifest.sh       — manifest_record_dispose, manifest_open_processes,
#                           manifest_process_id, manifest_process_is_same
# This file does not re-source them itself to avoid redefining functions when
# a caller already sourced a differently-configured copy (mirrors
# resolve-project.sh's own comment on this).

: "${SKILL_DIR:?gc.sh requires SKILL_DIR}"

_gc_run_dir() { printf '%s/run' "$SKILL_DIR"; }

# Reap dead codex-bridge.<team>.<name>.{pid,meta,log,appserver} sets.
#
# PID SPACE NOTE: this pidfile is written by codex-bridge.js's writeMeta()
# with NODE'S OWN `process.pid` — a Windows-NATIVE pid, not an MSYS one.
# codex-bridge-launcher.sh backgrounds it as `nohup node ... &`; `nohup`
# interposes a bash subshell, so bash's `$!` in that launcher is the
# subshell's MSYS pid, NOT the Node process — confirmed empirically (see
# manifest.sh's PID SPACE DECISION comment) that they are two different
# numbers. Liveness/cmdline MUST use the native-space helpers
# (_agmsg_pid_alive from instance-id.sh, compat_get_native_cmdline from
# compat.sh) — plain `kill -0`/compat_get_cmdline on this pid reliably reports
# "dead" for a process that is very much alive, which would make this
# function delete a live bridge's pidfile out from under it.
#
# A pidfile is "dead" when its recorded pid is empty, or alive-but-not-ours
# (cmdline no longer mentions codex-bridge — a recycled pid took over), or
# genuinely not running. Mirrors stop_codex_bridge's own confirm-before-kill
# discipline (delivery.sh), but this path only ever REMOVES already-dead
# artifacts — it never kills a live, confirmed-ours bridge (that is
# `delivery.sh set off`'s job; a live bridge is a running feature, not
# garbage).
#
# Requires lib/instance-id.sh sourced (for _agmsg_pid_alive) in addition to
# this file's usual compat.sh/manifest.sh requirement.
#
# Echoes the number of pidfile sets reaped, for observability.
agmsg_gc_codex_bridge_pidfiles() {
  local dir; dir="$(_gc_run_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f pid cmd reaped=0
  for f in "$dir"/codex-bridge.*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
      rm -f "$f" "${f%.pid}.meta" "${f%.pid}.log" "${f%.pid}.appserver"
      reaped=$((reaped + 1))
      continue
    fi
    if _agmsg_pid_alive "$pid" 2>/dev/null; then
      cmd="$(compat_get_native_cmdline "$pid" 2>/dev/null || true)"
      case "$cmd" in
        *codex-bridge*) continue ;;  # alive and confirmed ours — leave it
        *) ;;  # alive but a recycled pid took over; the bridge is gone
      esac
    fi
    rm -f "$f" "${f%.pid}.meta" "${f%.pid}.log" "${f%.pid}.appserver"
    reaped=$((reaped + 1))
  done
  echo "$reaped"
}

# Reap dead codex-app-server.<hash>.{pid,port,log,version} sets. Same
# confirm-before-touch rule as stop_codex_bridge's app-server teardown: only
# ever removes a record whose pid is dead, or alive-but-cmdline-mismatched
# (recycled pid). Never kills a live, confirmed app-server — that is a
# *shared* resource across bridges (see agmsg-multi-codex-monitor-design.md);
# tearing it down is out of scope for a startup reaper and stays with
# `delivery.sh set off`.
#
# NOTE: codex-app-server.<hash>.idle-ttl.pid (the WP2 idle-TTL reaper loop's
# OWN pidfile, see idle-ttl.sh / codex-monitor.sh) also matches the
# codex-app-server.*.pid glob below by construction (it shares the
# codex-app-server.<hash> prefix). It is deliberately skipped here and handled
# by agmsg_gc_codex_idle_ttl_pidfiles instead — it names a different process
# (a bash reaper loop, not the app-server) with a different liveness check and
# a different "is this mine" confirmation string, so folding it into this
# function's codex*app-server* cmdline match would either wrongly treat a live
# reaper as a dead app-server record (different process, same glob) or
# wrongly confirm a dead reaper pidfile as live via an app-server's own cmdline
# happening to also match *codex*app-server* (the reaper's OWN cmdline does
# contain that substring, being a `source ...idle-ttl.sh; idle_ttl_run_loop
# ...` script — but that is not "is this our app-server", it would be a false
# positive for the wrong question).
#
# Echoes the number of record sets reaped.
agmsg_gc_codex_app_server_pidfiles() {
  local dir; dir="$(_gc_run_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f pid cmd reaped=0
  for f in "$dir"/codex-app-server.*.pid; do
    [ -f "$f" ] || continue
    case "$f" in *.idle-ttl.pid) continue ;; esac
    pid="$(cat "$f" 2>/dev/null || true)"
    local base="${f%.pid}"
    if [ -z "$pid" ]; then
      rm -f "$f" "$base.port" "$base.log" "$base.version"
      reaped=$((reaped + 1))
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
      case "$cmd" in
        *codex*app-server*) continue ;;  # alive and confirmed ours — leave it
        *) ;;
      esac
    fi
    rm -f "$f" "$base.port" "$base.log" "$base.version"
    reaped=$((reaped + 1))
  done
  echo "$reaped"
}

# Reap dead codex-app-server.<hash>.idle-ttl.{pid,log} sets — the WP2 idle-TTL
# reaper loop's own bookkeeping (see idle-ttl.sh / codex-monitor.sh's
# IDLE_TTL_PID_FILE). This loop is launched `bash -c "<script>" &` (msys
# space — plain `&`, no nohup — so bash's own $! IS the loop's pid directly,
# same as the app-server's own launch; see codex-monitor.sh's PID STABILITY
# NOTE), so liveness/cmdline here use the same msys-space helpers as the
# app-server pidfile reaper above, not the native-space ones the codex-bridge
# reaper needs.
#
# Echoes the number of record sets reaped.
agmsg_gc_codex_idle_ttl_pidfiles() {
  local dir; dir="$(_gc_run_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f pid cmd reaped=0
  for f in "$dir"/codex-app-server.*.idle-ttl.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    local base="${f%.pid}"
    if [ -z "$pid" ]; then
      rm -f "$f" "$base.log"
      reaped=$((reaped + 1))
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
      case "$cmd" in
        *idle_ttl_run_loop*) continue ;;  # alive and confirmed ours — leave it
        *) ;;
      esac
    fi
    rm -f "$f" "$base.log"
    reaped=$((reaped + 1))
  done
  echo "$reaped"
}

# Reap a dead companion-waker PoC codex-app-server-owner.js record
# (scripts/poc/codex-app-server-owner.js): pid/port/endpoint/log written under
# its own --run-dir (default run/poc-codex-app-server, NOT this repo's
# manifest-tracked $SKILL_DIR/run — see that script's header comment on why
# the ledger write target and the --run-dir it writes its OWN files under are
# deliberately different paths).
#
# PID SPACE NOTE: the pidfile holds the app-server CHILD's pid as Node's own
# `child_process.spawn(...).pid` reports it — a Windows-NATIVE pid, the same
# reporting shape codex-bridge.js's writeMeta() uses (see manifest.sh's PID
# SPACE DECISION). Liveness/cmdline MUST use the native-space helpers
# (_agmsg_pid_alive, compat_get_native_cmdline) — a plain `kill -0` on this pid
# reliably reports "dead" for a live process, which would delete a live
# owner-managed app-server's record out from under it.
#
# Same confirm-before-touch discipline as the mainline bridge/app-server
# reapers above: only ever removes an ALREADY-dead (or recycled-pid) record.
# Never kills a live, confirmed process — this is reap-on-startup hygiene, not
# `delivery.sh set off`'s teardown job.
#
# Usage: agmsg_gc_poc_waker_app_server_owner_pidfiles [run_dir]
#   run_dir defaults to $SKILL_DIR/run/poc-codex-app-server (the PoC script's
#   own default --run-dir when invoked with no override).
# Echoes the number of record sets reaped.
agmsg_gc_poc_waker_app_server_owner_pidfiles() {
  local dir="${1:-$SKILL_DIR/run/poc-codex-app-server}"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f="$dir/codex-app-server.pid"
  [ -f "$f" ] || { echo 0; return 0; }
  local pid cmd
  pid="$(cat "$f" 2>/dev/null || true)"
  local base="${f%.pid}"
  if [ -z "$pid" ]; then
    rm -f "$f" "$base.port" "$base.endpoint"
    echo 1
    return 0
  fi
  if _agmsg_pid_alive "$pid" 2>/dev/null; then
    cmd="$(compat_get_native_cmdline "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *codex*app-server*) echo 0; return 0 ;;  # alive and confirmed ours — leave it
      *) ;;
    esac
  fi
  rm -f "$f" "$base.port" "$base.endpoint"
  echo 1
}

# Reap a dead companion-waker PoC delivery-supervisor.js record
# (scripts/poc/delivery-supervisor.js): port/lock/mailbox/state/events/
# adapter.log written under its own --run-dir (default
# run/poc-delivery-supervisor, same "own --run-dir differs from the
# manifest-tracked $SKILL_DIR/run" reasoning as the app-server-owner reaper
# above). The lock file's JSON body carries the supervisor's own pid (see
# delivery-supervisor.js Supervisor.start(): `{pid, port, project}`), the same
# native-pid reporting shape as codex-bridge.js.
#
# Same confirm-before-touch discipline: only removes a record whose recorded
# pid is dead, or alive-but-not-ours (recycled pid — cmdline no longer
# mentions delivery-supervisor). Never kills a live, confirmed supervisor.
#
# Usage: agmsg_gc_poc_waker_delivery_supervisor_pidfiles [run_dir]
#   run_dir defaults to $SKILL_DIR/run/poc-delivery-supervisor.
# Echoes the number of record sets reaped (one project-keyed supervisor per
# lock file; a run_dir can hold more than one, one per project hash).
agmsg_gc_poc_waker_delivery_supervisor_pidfiles() {
  local dir="${1:-$SKILL_DIR/run/poc-delivery-supervisor}"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f pid cmd reaped=0
  for f in "$dir"/supervisor.*.lock; do
    [ -f "$f" ] || continue
    pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)"
    local key="${f#"$dir"/supervisor.}"
    key="${key%.lock}"
    local prefix="$dir/supervisor.$key"
    if [ -z "$pid" ]; then
      rm -f "$f" "$prefix.port" "$prefix.mailbox.jsonl" "$prefix.state.json" "$prefix.events.log" "$prefix.adapter.log"
      reaped=$((reaped + 1))
      continue
    fi
    if _agmsg_pid_alive "$pid" 2>/dev/null; then
      cmd="$(compat_get_native_cmdline "$pid" 2>/dev/null || true)"
      case "$cmd" in
        *delivery-supervisor*) continue ;;  # alive and confirmed ours — leave it
        *) ;;
      esac
    fi
    rm -f "$f" "$prefix.port" "$prefix.mailbox.jsonl" "$prefix.state.json" "$prefix.events.log" "$prefix.adapter.log"
    reaped=$((reaped + 1))
  done
  echo "$reaped"
}

# Walk manifest.jsonl for kind=process entries with no matching dispose
# event, and for each: if the recorded pid is dead, or alive-but-cmdline-
# mismatched (recycled pid — never ours), record a dispose event and report
# it for cleanup. If the recorded pid is alive AND cmdline-confirmed ours,
# it is left alone UNLESS the caller explicitly asks this entry's owner
# session be treated as gone (see agmsg_gc_manifest_kill_orphans below) —
# plain scanning never kills a live, confirmed process.
#
# Prints one line per newly-disposed (already-dead) entry:
#   <pid><TAB><cmdline>
# Echoes nothing extra; caller decides what "already-dead" cleanup, if any,
# is owed beyond the manifest's own bookkeeping (the manifest itself is the
# source of truth here — kind=process entries do not necessarily have a
# corresponding pidfile to also remove; some do (bridge/app-server, handled by
# the two functions above), some are one-shot processes with no file residue).
#
# Dispatches liveness/cmdline checks on each entry's recorded pidSpace (msys
# vs native — see manifest.sh's PID SPACE DECISION comment); using the wrong
# check for a pid's actual space either mis-reaps a live process (msys check
# on a native pid → false "dead") or leaks a genuinely dead one.
agmsg_gc_manifest_reap_dead() {
  local pid cmdline started_at pid_space
  while IFS="$(printf '\t')" read -r pid cmdline started_at pid_space; do
    [ -n "$pid" ] || continue
    local alive=0
    if [ "$pid_space" = "native" ]; then
      _agmsg_pid_alive "$pid" 2>/dev/null && alive=1
    else
      kill -0 "$pid" 2>/dev/null && alive=1
    fi
    # Delegate the cmdline-match to manifest_process_is_same (not a local
    # comparison) so both callers normalize a freshly-fetched cmdline the same
    # way before comparing — a raw compat_get_*cmdline result can contain
    # embedded newlines (e.g. a `bash -c "<multi-line>"` invocation) that the
    # manifest's own stored copy never has (collapsed at write time); comparing
    # without that same normalization made this function wrongly treat a live,
    # identical process as "not confirmed" (caught by this WP's own test suite).
    if [ "$alive" = 1 ] && manifest_process_is_same "$pid" "$cmdline" "$pid_space"; then
      continue  # alive and confirmed ours — not garbage
    fi
    # Either dead, or alive-but-not-confirmed-ours (recycled pid / cmdline
    # unreadable — fails closed: we stop tracking it as ours, but this
    # function never kills a live pid; see agmsg_gc_manifest_kill_orphans for
    # the only path allowed to do that).
    manifest_record_dispose process "$(manifest_process_id "$pid" "$cmdline" "$started_at" "$pid_space")" gc
    printf '%s\t%s\n' "$pid" "$cmdline"
  done < <(manifest_open_processes)
}

# Kill orphaned-but-still-alive manifest process entries whose createdBy
# token is no longer a live agmsg instance/session. Requires the caller to
# supply an "is this owner token still alive" predicate function name (agmsg
# already has two different owner-liveness notions in play — cc-instance pid
# for the watch.sh family via agmsg_instance_alive, and actas_lock_sid_alive
# for actas owners — so this file does not hardcode one).
#
# Usage: agmsg_gc_manifest_kill_orphans <owner_alive_predicate_fn>
#   <owner_alive_predicate_fn> "$owner_token" must return 0 (alive) / 1 (dead).
#
# Only kills when: (a) predicate says the owner is dead, AND (b) the pid is
# alive AND cmdline-confirmed ours (manifest_process_is_same). This is the
# one function in this file allowed to kill a live pid — everything else only
# removes records for pids already confirmed dead.
agmsg_gc_manifest_kill_orphans() {
  local owner_alive_fn="$1"
  [ -n "$owner_alive_fn" ] || return 1
  local path; path="$SKILL_DIR/run/manifest.jsonl"
  [ -f "$path" ] || return 0
  local disposed_pids created_line pid cmdline started_at pid_space created_by killed=0
  local is_alive=0
  disposed_pids="$(grep '"event":"dispose"' "$path" 2>/dev/null \
    | grep '"kind":"process"' \
    | sed -n 's/.*"pid":"\([^"]*\)".*/\1/p' || true)"
  while IFS= read -r created_line; do
    [ -n "$created_line" ] || continue
    case "$created_line" in *'"kind":"process"'* ) ;; *) continue ;; esac
    pid="$(_manifest_id_field "$created_line" pid)"
    [ -n "$pid" ] || continue
    printf '%s\n' "$disposed_pids" | grep -Fxq "$pid" && continue
    created_by="$(_manifest_field "$created_line" createdBy)"
    [ -n "$created_by" ] || continue
    if "$owner_alive_fn" "$created_by"; then
      continue  # owner still alive — this process is legitimately running
    fi
    cmdline="$(_manifest_id_field "$created_line" cmdline)"
    started_at="$(_manifest_id_field "$created_line" startedAt)"
    pid_space="$(_manifest_id_field "$created_line" pidSpace)"
    [ -n "$pid_space" ] || pid_space="msys"
    if [ "$pid_space" = "native" ]; then
      _agmsg_pid_alive "$pid" 2>/dev/null && is_alive=1 || is_alive=0
    else
      kill -0 "$pid" 2>/dev/null && is_alive=1 || is_alive=0
    fi
    if [ "$is_alive" = 1 ] && manifest_process_is_same "$pid" "$cmdline" "$pid_space"; then
      kill "$pid" 2>/dev/null || true
      killed=$((killed + 1))
    fi
    manifest_record_dispose process "$(manifest_process_id "$pid" "$cmdline" "$started_at" "$pid_space")" gc
  done < <(grep '"event":"create"' "$path" 2>/dev/null)
  echo "$killed"
}

# One-call entry point for session-start.sh: runs every gc step this file
# owns, in the order that keeps each step's assumptions valid (bridge
# pidfiles before app-server records mirrors stop_codex_bridge's own
# per-bridge-then-per-server order). Best-effort throughout — never aborts
# the caller's SessionStart flow. Unknown manifest kinds are left untouched
# (forward-compat: a future kind this file doesn't know about is simply not
# scanned, not treated as garbage).
agmsg_gc_run_all() {
  agmsg_gc_codex_bridge_pidfiles >/dev/null 2>&1 || true
  agmsg_gc_codex_app_server_pidfiles >/dev/null 2>&1 || true
  agmsg_gc_codex_idle_ttl_pidfiles >/dev/null 2>&1 || true
  agmsg_gc_poc_waker_app_server_owner_pidfiles >/dev/null 2>&1 || true
  agmsg_gc_poc_waker_delivery_supervisor_pidfiles >/dev/null 2>&1 || true
  agmsg_gc_manifest_reap_dead >/dev/null 2>&1 || true
}
