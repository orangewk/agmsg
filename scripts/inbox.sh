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
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load
DB="$(agmsg_db_path)"

# Preserve the read-only "not initialized yet" behaviour: an inbox check must not
# create the store, so guard on the file before touching the facade.
if [ ! -f "$DB" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

# Unread comes from the storage facade (§2.1 storage_list_unread = the event log
# UNION the legacy messages table), as one JSONL record per line in delivery
# order. Parse it with sqlite's JSON funcs in a single pass — the repo idiom, no
# jq dependency (cf. lib/hooks-json.sh).
UNREAD_JSONL=$(storage_list_unread "$TEAM" "$AGENT")

if [ -z "$UNREAD_JSONL" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# JSONL -> JSON array -> "from \x1f body \x1f at" rows (newlines/tabs in the body
# escaped so each message stays one display line).
_arr="[$(printf '%s' "$UNREAD_JSONL" | paste -sd, -)]"
ROWS=$(agmsg_sqlite ':memory:' "
  SELECT json_extract(value,'\$.from') || char(31) ||
         replace(replace(json_extract(value,'\$.body'), char(10), '\n'), char(9), '\t') || char(31) ||
         json_extract(value,'\$.at')
  FROM json_each('$(printf '%s' "$_arr" | sed "s/'/''/g")');
")

COUNT=$(printf '%s\n' "$ROWS" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
while IFS=$'\x1f' read -r from body ts; do
  [ -n "$ts$from$body" ] || continue
  echo "  [$ts] $from: $body"
done <<< "$ROWS"
echo ""

# Mark read — transitional legacy UPDATE, NOT storage_mark_read_batch yet. The
# read-state writers (inbox/check-inbox) and the legacy-read_at readers that have
# not migrated (watch-once, whose codex-bridge consumes an integer max_id cursor)
# must flip together at step 3 (send → events + watch → facade). Marking via
# events now would be invisible to those readers and split read-state. Non-fatal.
agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE team='$TEAM' AND to_agent='$AGENT' AND read_at IS NULL;" 2>/dev/null || true
