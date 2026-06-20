#!/usr/bin/env bash
set -euo pipefail

# Launch Codex with agmsg's app-server bridge enabled.
#
# This is a beta convenience wrapper: it hides the shared app-server socket and
# lets session-start.sh launch codex-bridge.js in the background once Codex
# exposes CODEX_THREAD_ID to hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

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
PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum | awk '{print $1}')"
SERVER_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.log"
SERVER_PID="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"
PORT_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.port"

mkdir -p "$RUN_DIR"

# codex 0.141+ accepts only ws:// (not unix://) for the TUI's --remote, so the
# shared app-server listens on a loopback ws port instead of a unix socket. The
# port is recorded per project so a second monitor reuses a live server. See #170.
port_alive() {  # $1 = port; succeeds if something is accepting on 127.0.0.1:$1
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

PORT=""
if [ -f "$PORT_FILE" ]; then
  existing_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
  if [ -n "$existing_port" ] && port_alive "$existing_port"; then
    PORT="$existing_port"
  fi
fi

if [ -z "$PORT" ]; then
  PORT="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{process.stdout.write(String(s.address().port));s.close();});' 2>/dev/null || true)"
  if [ -z "$PORT" ]; then
    echo "codex-monitor: could not allocate a loopback port (is node available?)" >&2
    exit 1
  fi
  "$REAL_CODEX" app-server --listen "ws://127.0.0.1:$PORT" >>"$SERVER_LOG" 2>&1 &
  echo "$!" > "$SERVER_PID"
  printf '%s' "$PORT" > "$PORT_FILE"
  for _ in $(seq 1 50); do
    port_alive "$PORT" && break
    sleep 0.1
  done
fi

if ! port_alive "$PORT"; then
  echo "codex-monitor: app-server did not start on ws://127.0.0.1:$PORT" >&2
  echo "codex-monitor: see $SERVER_LOG" >&2
  exit 1
fi
SOCKET_URL="ws://127.0.0.1:$PORT"

"$SCRIPT_DIR/delivery.sh" set monitor codex "$PROJECT" >/dev/null

export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
export AGMSG_CODEX_BRIDGE_LAUNCHER=1

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" >/dev/null 2>&1 &

cd "$PROJECT"
case "$CODEX_COMMAND" in
  codex)
    exec "$REAL_CODEX" --remote "$SOCKET_URL" "${CODEX_ARGS[@]}"
    ;;
  resume)
    exec "$REAL_CODEX" resume --remote "$SOCKET_URL" "${CODEX_ARGS[@]}"
    ;;
esac
