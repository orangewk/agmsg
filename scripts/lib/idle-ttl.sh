#!/usr/bin/env bash
# idle-ttl.sh — held-connection idle TTL for the shared codex app-server
# (orangewk/agmsg#8, WP2).
#
# Background: codex-monitor.sh starts ONE codex app-server per project and
# shares it across every codex-bridge.js that attaches to it (see
# agmsg-multi-codex-monitor-design.md: "don't kill a server other bridges
# still need"). Nothing ever shuts that server down except an explicit
# `delivery.sh set off codex` (stop_codex_bridge) or the reap-on-startup gc in
# gc.sh finding it already dead. A user who just closes every codex window
# leaves the app-server running forever.
#
# LIVENESS MODEL — held-connection, NOT heartbeat. This is an explicit
# constraint handed down in docs/poc-delivery-supervisor-notes.md's "feasibility
# verdict and liveness design handoff" section (decision owner: orange):
#   "Replace timestamp heartbeat with held-connection liveness."
#   "Do not add per-session timer processes just to keep liveness fresh."
#   "Treat the already-required delivery connection as the liveness primitive:
#    open connection/register frame = live seat binding, transport drop = dead."
#
# Every codex-bridge.js that talks to this app-server does so over a
# WebSocketAppServerClient TCP socket held open for the bridge's entire
# lifetime (see codex-bridge.js's `net.createConnection` — it is not a
# request/response poll, the socket stays connected). That already-required
# connection IS the liveness primitive this file reads: it asks the OS how
# many TCP peers are currently ESTABLISHED on the app-server's loopback port,
# via `Get-NetTCPConnection` (confirmed empirically to report 1 while a client
# socket is connected and 0 immediately after it disconnects — no polling of
# any agmsg-owned timestamp file is involved). Zero established peers means
# zero live bridges, full stop — nothing to ask an "is it fresh" question
# about, unlike a heartbeat file whose staleness is itself a judgment call.
#
# This file adds NO per-session timer: the TTL loop below is per-app-server
# (one loop per shared project-scoped server, mirroring codex-monitor.sh's own
# "one app-server per project" unit — see PORT_FILE/SERVER_PID keying), not
# per bridge/session/thread. A project with 5 codex sessions attached still
# has exactly one app-server and exactly one idle-ttl reaper loop for it.
#
# FAIL-CLOSED: any failure to determine the connection count (powershell.exe
# missing/erroring, non-Windows platform, transient WMI hiccup) is treated as
# "cannot confirm idle" and resets the idle streak — never as "confirmed
# idle". A live, shared resource is not shut down on ambiguous evidence.
#
# Required caller-set variable: SKILL_DIR (agmsg skill root; run/ hangs off it).

: "${SKILL_DIR:?idle-ttl.sh requires SKILL_DIR}"

_idle_ttl_run_dir() { printf '%s/run' "$SKILL_DIR"; }

# Count TCP peers currently ESTABLISHED on 127.0.0.1:<port>. Prints a
# non-negative integer on success. Prints nothing (empty stdout, non-zero
# exit) when the count cannot be determined — callers MUST treat empty output
# as "unknown", never as zero, to keep the fail-closed contract above.
#
# Windows-only for now (Get-NetTCPConnection is a Windows networking cmdlet);
# a Linux/macOS build of agmsg would need an `ss`/`lsof` counterpart, out of
# scope here since codex-monitor.sh's own app-server hosting is Windows-only
# in production today (see codex-monitor.sh's port_alive comment / #170).
idle_ttl_established_count() {
  local port="$1"
  [ -n "$port" ] || return 1
  case "$port" in *[!0-9]*) return 1 ;; esac
  case "${MSYSTEM:-}" in
    MINGW*|MSYS*|CLANGARM*) ;;
    *) return 1 ;;
  esac
  local out
  out="$(powershell.exe -NoProfile -Command \
    "(Get-NetTCPConnection -LocalPort $port -State Established -ErrorAction SilentlyContinue | Measure-Object).Count" \
    2>/dev/null | tr -d '\r\n ')"
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# Run the idle-TTL reaper loop for one app-server, forever, until either (a)
# the app-server pid itself dies (nothing left to reap — exit quietly), or
# (b) established-connection count has been 0 for >= ttl_seconds, in which
# case this function kills the app-server, records the manifest dispose, and
# exits. Intended to be launched once per app-server (see the pidfile guard
# in codex-monitor.sh) as a detached background process — NOT sourced inline,
# so a crash/kill of this loop cannot wedge codex-monitor.sh or a TUI session.
#
# Usage: idle_ttl_run_loop <port> <server_pid> <server_pidfile> <ttl_seconds> <poll_seconds>
#   <server_pid>       msys-space pid of the app-server (codex-monitor.sh's
#                       $server_bg — a plain `&` background of native codex.exe,
#                       confirmed 1:1 with the native pid; see manifest.sh's PID
#                       SPACE DECISION comment for why this differs from the
#                       nohup-wrapped bridge launch).
#   <server_pidfile>   path whose content is compared against <server_pid> on
#                       every iteration; if the file now names a DIFFERENT pid
#                       (codex-monitor.sh replaced the server, e.g. a version
#                       mismatch reuse-rejection) this loop's authority over
#                       the OLD server has been superseded — exit without
#                       touching the new one.
idle_ttl_run_loop() {
  # ${4:-}/${5:-} (not "$4"/"$5"): this function runs under a caller's
  # `set -u` (codex-monitor.sh, and every test in tests/test-idle-ttl.cjs);
  # omitting the optional ttl/poll args must fall through to this function's
  # own defaults below, not blow up the whole detached loop with "$4: unbound
  # variable" before it ever gets a chance to apply them.
  local port="$1" server_pid="$2" server_pidfile="$3" ttl_seconds="${4:-}" poll_seconds="${5:-}"
  [ -n "$port" ] && [ -n "$server_pid" ] && [ -n "$server_pidfile" ] || return 1
  [ -n "$ttl_seconds" ] || ttl_seconds=900
  [ -n "$poll_seconds" ] || poll_seconds=30

  local idle_elapsed=0 count current_owner
  while :; do
    sleep "$poll_seconds"

    # The app-server died on its own (killed by `set off`, crashed, upgraded
    # away) — nothing left for this loop to own. Exit quietly; gc.sh's own
    # reap-on-startup / stop_codex_bridge already handle pidfile cleanup for a
    # server that's gone, this loop does not duplicate that.
    kill -0 "$server_pid" 2>/dev/null || return 0

    # A newer codex-monitor.sh invocation replaced the recorded server (stale
    # version reuse-rejection in codex-monitor.sh) — this loop's server_pid is
    # no longer the one on record. Its own successor loop (started by that
    # invocation) now owns the new server; stop shadowing it.
    current_owner="$(cat "$server_pidfile" 2>/dev/null || true)"
    [ "$current_owner" = "$server_pid" ] || return 0

    # `|| true`: idle_ttl_established_count returns non-zero (empty stdout)
    # whenever the count can't be determined (see its own fail-closed
    # contract) — under this loop's caller's `set -e`, an UNGUARDED failing
    # command substitution here would kill the ENTIRE detached loop process on
    # the very first ambiguous tick, which is the opposite of fail-closed (it
    # would silently stop watching the app-server at all, rather than just
    # skipping one TTL-accumulation tick). Caught by this WP's own test suite
    # (a bare `count="$(...)"` here made every idle_ttl_run_loop test that
    # exercises a live TCP listener capable of erroring silently and exiting 0
    # with zero effect, all its assertions failing on "nothing happened").
    count="$(idle_ttl_established_count "$port" || true)"
    if [ -z "$count" ]; then
      # Fail-closed: count unknown this tick. Do not accumulate idle time on
      # ambiguous evidence, but do not reset silently either — treat exactly
      # like "not idle" (below) since this branch and count=0's "reset" arm
      # would otherwise duplicate; both simply skip TTL accumulation this poll.
      idle_elapsed=0
      continue
    fi
    if [ "$count" = "0" ]; then
      idle_elapsed=$((idle_elapsed + poll_seconds))
      if [ "$idle_elapsed" -ge "$ttl_seconds" ]; then
        break
      fi
    else
      idle_elapsed=0
    fi
  done

  # TTL elapsed with zero held connections throughout. Kill the (still
  # confirmed-alive, still confirmed-current) app-server and record disposal.
  # This mirrors stop_codex_bridge's own confirm-before-kill discipline
  # (delivery.sh) rather than introducing a third kill-path convention.
  #
  # Caller contract: manifest.sh (manifest_record_dispose, manifest_process_id)
  # MUST already be sourced by the caller before invoking idle_ttl_run_loop, the
  # same "caller sources, this file doesn't re-source" convention gc.sh uses
  # (see gc.sh's own header comment) — this file does not guard-source it so a
  # caller with a differently-configured copy (e.g. a test double) is never
  # silently shadowed.
  kill "$server_pid" 2>/dev/null || true
  manifest_record_dispose process \
    "$(manifest_process_id "$server_pid" "" "" msys)" \
    "idle-ttl (no held bridge connections for ${ttl_seconds}s)"
  rm -f "$server_pidfile"
}
