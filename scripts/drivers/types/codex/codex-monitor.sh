#!/usr/bin/env bash
set -euo pipefail

# Launch Codex with agmsg's app-server bridge enabled.
#
# This is a beta convenience wrapper: it hides the shared app-server socket and
# lets session-start.sh launch codex-bridge.js in the background once Codex
# exposes CODEX_THREAD_ID to hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/compat.sh
source "$SCRIPT_DIR/../../../lib/compat.sh"
# shellcheck source=../../../lib/manifest.sh
source "$SCRIPT_DIR/../../../lib/manifest.sh"
# idle-ttl.sh is NOT sourced here: this script never calls idle_ttl_run_loop
# itself (only launches it as a separate `bash -c "source ...; idle_ttl_run_loop
# ..."` process below, see the "Ensure an idle-TTL reaper loop" block), so
# sourcing it into THIS process's own function table would be dead weight.

PROJECT="$(pwd)"
SOCKET_PATH=""
CODEX_COMMAND="resume"
CODEX_ARGS=()
REAL_CODEX="${AGMSG_REAL_CODEX:-codex}"

usage() {
  cat <<EOF
Usage: codex-monitor.sh [--project <path>] [--codex-command <codex|resume>] [-- <args...>]

Starts/reuses an agmsg-managed Codex app-server on a loopback ws:// port,
enables agmsg Codex bridge delivery for this project, then execs:
  codex resume --remote ws://127.0.0.1:<port>

(--socket-path is accepted for compatibility but ignored: codex 0.141+ requires
a ws:// transport for --remote. See #170.)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --project)
      PROJECT="${2:?--project requires a path}"
      shift 2
      ;;
    --socket-path)
      SOCKET_PATH="${2:?--socket-path requires a path}"
      shift 2
      ;;
    --codex-command)
      CODEX_COMMAND="${2:?--codex-command requires codex or resume}"
      shift 2
      ;;
    --)
      shift
      CODEX_ARGS=("$@")
      break
      ;;
    *)
      CODEX_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$CODEX_COMMAND" in
  codex|resume) ;;
  *)
    echo "codex-monitor: --codex-command must be 'codex' or 'resume'" >&2
    exit 1
    ;;
esac

PROJECT="$(cd "$PROJECT" && pwd)"

# Fail-open: never let a broken bridge block codex. If the agmsg app-server can't
# be brought up — e.g. a codex release changes the app-server interface and the
# launch/port detection fails — hand off to a plain codex session (no --remote
# bridge) instead of erroring out. The user keeps a working codex; only the
# agmsg monitor delivery is skipped for this launch.
#
# This is a LOUD fallback: it only runs on UNEXPECTED failure (the explicit
# AGMSG_CODEX_SHIM_DISABLE=1 bypass is handled in codex-shim.sh and never reaches
# here), so it must tell the user, on screen, that real-time delivery is off —
# otherwise message receipt stops silently. The earlier echoes give the specific
# reason + log path; this prints the one-line summary just before handoff.
exec_plain_codex() {
  echo "agmsg: Codex monitor bridge unavailable - launching plain Codex. Real-time agmsg delivery is OFF this session (messages still queue; check your inbox manually). Likely cause: the Codex app-server interface changed in 0.142+. Fix in progress." >&2
  cd "$PROJECT" 2>/dev/null || true
  case "$CODEX_COMMAND" in
    codex)  exec "$REAL_CODEX" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} ;;
    resume) exec "$REAL_CODEX" resume ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} ;;
  esac
}

PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
SERVER_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.log"
SERVER_PID="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"
PORT_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.port"
# Records the codex version that launched the reusable app-server. A TUI from a
# newer/older codex can't speak to an app-server from a different build, so a
# stale server left running across a codex upgrade must not be reused.
VERSION_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.version"
CODEX_VERSION="$("$REAL_CODEX" --version 2>/dev/null || true)"
# Idle-TTL reaper loop pid for THIS app-server (see idle-ttl.sh). One loop per
# shared app-server, not per bridge/session — keyed on the same PROJECT_HASH
# as the server it watches.
IDLE_TTL_PID_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.idle-ttl.pid"
IDLE_TTL_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.idle-ttl.log"
# Default 15 minutes, matching the WP2 brief's default. Both are overridable
# per-invocation for tests / operators who want a different budget.
IDLE_TTL_SECONDS="${AGMSG_CODEX_APPSERVER_IDLE_TTL_SECONDS:-900}"
IDLE_TTL_POLL_SECONDS="${AGMSG_CODEX_APPSERVER_IDLE_POLL_SECONDS:-30}"

mkdir -p "$RUN_DIR"

# codex 0.141+ accepts only ws:// (not unix://) for the TUI's --remote, so the
# shared app-server listens on a loopback ws port instead of a unix socket. The
# port is recorded per project so a second monitor reuses a live server. See #170.
port_alive() {  # $1 = port; succeeds if something is accepting on 127.0.0.1:$1
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

PORT=""
if [ -f "$PORT_FILE" ] && [ -f "$SERVER_PID" ]; then
  existing_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
  existing_pid="$(cat "$SERVER_PID" 2>/dev/null || true)"
  existing_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
  # Reuse only when OUR recorded app-server is still alive AND its port answers,
  # so a foreign process that grabbed the same port after ours died is not
  # mistaken for the bridge app-server.
  if [ -n "$existing_port" ] && [ -n "$existing_pid" ] \
    && kill -0 "$existing_pid" 2>/dev/null && port_alive "$existing_port"; then
    # Confirm the recorded pid is actually OUR codex app-server before trusting OR
    # killing it: a recycled pid could belong to an unrelated process while the
    # recorded port happens to answer via something else. Only reuse/kill when the
    # cmdline proves it.
    existing_cmd="$(compat_get_cmdline "$existing_pid" 2>/dev/null || true)"
    case "$existing_cmd" in
      *codex*app-server*)
        # ...and only when it was launched by THIS codex build. A codex upgrade
        # leaves the old app-server running on the recorded port; the port still
        # answers, but a new TUI's --remote can't speak to the old server and dies
        # with "failed to connect to remote app server". Treat a version mismatch
        # as stale: kill the (confirmed-ours) old server and start fresh. If we
        # can't read the current version, fall back to liveness-only reuse.
        if [ -z "$CODEX_VERSION" ] || [ "$existing_version" = "$CODEX_VERSION" ]; then
          PORT="$existing_port"
        else
          kill "$existing_pid" 2>/dev/null || true
          rm -f "$PORT_FILE" "$SERVER_PID" "$VERSION_FILE"
        fi
        ;;
      *)
        # Can't confirm it's our app-server (pid reuse / a foreign listener on the
        # recorded port): do NOT kill it. Drop the stale artifacts and start a
        # fresh server of our own.
        rm -f "$PORT_FILE" "$SERVER_PID" "$VERSION_FILE"
        ;;
    esac
  fi
fi

if [ -z "$PORT" ]; then
  # Let the app-server pick a free loopback port (--listen ws://127.0.0.1:0) and
  # report it ("listening on: ws://127.0.0.1:<port>"). This keeps codex-monitor.sh
  # free of any Node dependency — only the bridge (codex-bridge.js) needs Node, and
  # it degrades on its own if Node is missing rather than taking down the TUI. See #170.
  : > "$SERVER_LOG"
  "$REAL_CODEX" app-server --listen "ws://127.0.0.1:0" >>"$SERVER_LOG" 2>&1 &
  server_bg="$!"
  echo "$server_bg" > "$SERVER_PID"
  # server_bg is a plain (non-nohup) `&` background of a native codex.exe, so
  # bash's $! IS the MSYS pid that maps 1:1 to that native process (confirmed
  # empirically — this differs from the nohup-wrapped codex-bridge.js launch,
  # where $! is a subshell pid instead; see manifest.sh's PID SPACE DECISION).
  manifest_record_create process \
    "$(manifest_process_id "$server_bg" "codex app-server --listen ws://127.0.0.1:0" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" msys)" \
    "$$" \
    "delivery.sh set off codex (stop_codex_bridge) kills by confirmed cmdline; gc reaps if dead"
  for _ in $(seq 1 100); do
    PORT="$(sed -n 's#.*listening on: ws://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' "$SERVER_LOG" | head -1)"
    [ -n "$PORT" ] && break
    # Stop waiting the moment the app-server exits (e.g. a codex release dropped
    # `app-server --listen ws://`): no point burning the full timeout before we
    # fail open.
    kill -0 "$server_bg" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$PORT" ]; then
    echo "codex-monitor: app-server did not report a listening port; starting codex without the agmsg bridge" >&2
    echo "codex-monitor: see $SERVER_LOG" >&2
    kill "$server_bg" 2>/dev/null || true
    rm -f "$SERVER_PID" "$VERSION_FILE"
    exec_plain_codex
  fi
  printf '%s' "$PORT" > "$PORT_FILE"
  # Stamp the version that owns this server so a later launch from a different
  # codex build recreates it instead of reusing a stale one.
  printf '%s' "$CODEX_VERSION" > "$VERSION_FILE"
fi

# Ensure an idle-TTL reaper loop is watching THIS app-server (see idle-ttl.sh
# for the held-connection design). Covers both the fresh-launch path above
# (no loop exists yet) and the reuse path (a prior codex-monitor.sh's loop may
# already be running, or may have exited abnormally and left a stale pidfile —
# start one only when no confirmed-alive loop for the CURRENT $SERVER_PID
# already exists, so two concurrent codex-monitor.sh launches for the same
# project never race into two competing reapers).
#
# PID STABILITY NOTE: launched as `bash -c "<script>" &` (NOT `nohup ... &`,
# and NOT a bare `( ... ) &` subshell). Confirmed empirically (WP2 repro):
#   - a bare `( ... ) &` subshell whose last command is a simple external
#     command gets exec-optimized away — bash's $! then names the LAST
#     command run inside the loop (a `sleep` invocation), a pid that changes
#     every poll interval, not the stable loop process.
#   - `bash -c "<script>"` containing a `while :; do ... done` loop does NOT
#     get exec-optimized (a shell builtin loop is not a single simple
#     command), so $! is bash's own pid for the entire loop lifetime, AND
#     /proc/<pid>/cmdline for that pid is the full script text — which is what
#     lets the reaper_alive check below positively identify "this pid IS our
#     idle-ttl loop for THIS project" instead of trusting a bare pid alone.
existing_reaper_pid="$(cat "$IDLE_TTL_PID_FILE" 2>/dev/null || true)"
reaper_alive=0
if [ -n "$existing_reaper_pid" ] && kill -0 "$existing_reaper_pid" 2>/dev/null; then
  reaper_cmd="$(compat_get_cmdline "$existing_reaper_pid" 2>/dev/null || true)"
  case "$reaper_cmd" in
    *"idle_ttl_run_loop $PORT "*) reaper_alive=1 ;;
  esac
fi
if [ "$reaper_alive" != 1 ]; then
  rm -f "$IDLE_TTL_PID_FILE"
  server_bg_for_ttl="$(cat "$SERVER_PID" 2>/dev/null || true)"
  if [ -n "$server_bg_for_ttl" ]; then
    idle_ttl_script="source $(printf '%q' "$SCRIPT_DIR/../../../lib/manifest.sh"); \
source $(printf '%q' "$SCRIPT_DIR/../../../lib/idle-ttl.sh"); \
idle_ttl_run_loop $(printf '%q' "$PORT") $(printf '%q' "$server_bg_for_ttl") \
$(printf '%q' "$SERVER_PID") $(printf '%q' "$IDLE_TTL_SECONDS") $(printf '%q' "$IDLE_TTL_POLL_SECONDS")"
    SKILL_DIR="$SKILL_DIR" bash -c "$idle_ttl_script" >>"$IDLE_TTL_LOG" 2>&1 &
    idle_ttl_bg="$!"
    echo "$idle_ttl_bg" > "$IDLE_TTL_PID_FILE"
  fi
fi

if ! port_alive "$PORT"; then
  echo "codex-monitor: app-server not reachable on ws://127.0.0.1:$PORT; starting codex without the agmsg bridge" >&2
  echo "codex-monitor: see $SERVER_LOG" >&2
  exec_plain_codex
fi
SOCKET_URL="ws://127.0.0.1:$PORT"

"$SCRIPT_DIR/../../../delivery.sh" set monitor codex "$PROJECT" >/dev/null

export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
export AGMSG_CODEX_BRIDGE_LAUNCHER=1

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" >/dev/null 2>&1 &

cd "$PROJECT"
# Guard the array expansion: under bash 3.2 + `set -u`, "${CODEX_ARGS[@]}" on an
# empty array errors with "unbound variable" (a no-arg `codex`/`codex resume`).
case "$CODEX_COMMAND" in
  codex)
    exec "$REAL_CODEX" --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
  resume)
    exec "$REAL_CODEX" resume --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
esac
