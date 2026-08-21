#!/usr/bin/env bash
set -euo pipefail

# current-instance.sh — resolve a Claude/Codex/etc. hook session to agmsg's
# read-only per-process owner token.
#
# Usage: current-instance.sh <type> <session_id>
#
# Output (stdout, key=value):
#   status=ok owner=<session_id>.<agent_pid>  composite owner token resolved
#   status=unknown                           no composite token is available
#
# Exit code:
#   0 — status=ok
#   1 — status=unknown
#
# A raw session id is deliberately never returned as `ok`: it collides across
# parallel --continue/--resume processes. Consumers that need per-process
# attribution must fail open when the agent process cannot be resolved.

TYPE="${1:?Usage: current-instance.sh <type> <session_id>}"
SESSION_ID="${2:?Missing session_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# resolve-project.sh provides agmsg_agent_pid and sources instance-id.sh.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

OWNER="$(agmsg_instance_id "$SESSION_ID" "$TYPE" 2>/dev/null || true)"
if ! agmsg_instance_is_composite "$OWNER"; then
  echo "status=unknown"
  exit 1
fi

printf 'status=ok owner=%s\n' "$OWNER"
