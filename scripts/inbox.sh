#!/usr/bin/env bash
set -euo pipefail

# Usage: inbox.sh <team> <agent_id> [--quiet]
# Shows unread messages and marks them as read.
# --quiet: only output if there are unread messages (for hooks)

TEAM="${1:?Usage: inbox.sh <team> <agent_id> [--quiet]}"
AGENT="${2:?Missing agent_id}"
QUIET=false
if [ "${3:-}" = "--quiet" ]; then
  QUIET=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/sync.sh"

# Remote transport (ADR 0005): a manual inbox check should see what other
# environments sent, so pull first. Best-effort — offline must not break the
# inbox — and the pull may CREATE the DB in a receive-only environment, so it
# runs before the -f check.
if [ -f "$(agmsg_storage_dir)/remote.conf" ]; then
  bash "$SCRIPT_DIR/remote.sh" pull --quiet >/dev/null 2>&1 || true
fi

DB="$(agmsg_db_path)"

if [ ! -f "$DB" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
TEAM_SQL="$(_agmsg_sqlesc "$TEAM")"
AGENT_SQL="$(_agmsg_sqlesc "$AGENT")"

# Get unread messages — escape newlines/tabs in body to keep one record per line
UNREAD=$(agmsg_sqlite "$DB" "
  SELECT from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
  FROM messages WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL' AND read_at IS NULL
  ORDER BY created_at ASC;
")

if [ -z "$UNREAD" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# Display
COUNT=$(echo "$UNREAD" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
while IFS=$'\x1f' read -r from body ts; do
  echo "  [$ts] $from: $body"
done <<< "$UNREAD"
echo ""

# Mark as read (non-fatal — may fail in sandboxed environments)
if sync_configured; then
  sync_mark_read "$DB" "$TEAM_SQL" "$AGENT_SQL" 2>/dev/null \
    || agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL' AND read_at IS NULL;" 2>/dev/null || true
  sync_push_best_effort
else
  agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL' AND read_at IS NULL;" 2>/dev/null || true
fi
