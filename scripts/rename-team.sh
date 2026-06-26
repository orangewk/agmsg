#!/usr/bin/env bash
set -euo pipefail

# Usage: rename-team.sh <old_team> <new_team>
#
# Renames a team:
#   1. moves teams/<old>/ to teams/<new>/
#   2. updates "name" field in the moved config.json
#   3. updates messages.db: UPDATE messages SET team=<new> WHERE team=<old>

OLD_TEAM="${1:?Usage: rename-team.sh <old_team> <new_team>}"
NEW_TEAM="${2:?Missing new team name}"

if [ "$OLD_TEAM" = "$NEW_TEAM" ]; then
  echo "Old and new team names are the same: $OLD_TEAM"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# Reject team names that would escape teams/ as a path segment, on either side
# of the rename (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$OLD_TEAM" || exit 1
agmsg_validate_team_name "$NEW_TEAM" || exit 1
TEAMS_DIR="$SCRIPT_DIR/../teams"
DB="$(agmsg_db_path)"
OLD_DIR="$TEAMS_DIR/$OLD_TEAM"
NEW_DIR="$TEAMS_DIR/$NEW_TEAM"

if [ ! -d "$OLD_DIR" ]; then
  echo "Team not found: $OLD_TEAM"
  exit 1
fi

if [ -e "$NEW_DIR" ]; then
  echo "Team already exists: $NEW_TEAM"
  exit 1
fi

# --- Move directory ---
mv "$OLD_DIR" "$NEW_DIR"

# --- Update name in config.json ---
# Read the config with readfile() (not `.param set`, whose dot-command tokenizer
# does NOT honour SQL '' escaping, so an apostrophe in the config content breaks
# the binding) and escape the new team name as a SQL string literal (#223, #87):
# a team name may contain a single quote (validate.sh only blocks path traversal).
# Mirrors join.sh's readfile-based, apostrophe-safe registry read.
NEW_CONFIG="$NEW_DIR/config.json"
if [ -f "$NEW_CONFIG" ]; then
  CONFIG_SQL=$(agmsg_sql_readfile_path "$NEW_CONFIG")
  NEW_TEAM_LIT=$(agmsg_sqlesc "$NEW_TEAM")
  UPDATED=$(agmsg_sqlite_mem \
    "SELECT json_set(CAST(readfile('$CONFIG_SQL') AS TEXT), '\$.name', '$NEW_TEAM_LIT');")
  echo "$UPDATED" > "$NEW_CONFIG"
fi

# --- Update messages in DB ---
# Rewrite the team name in BOTH stores: the event log (where storage_send now
# writes) and the legacy messages table (pre-event-log installs). Without the
# events update a rename would orphan every message sent after the storage flip.
# Escape both team names as SQL string literals (#223, #87): a team name may
# contain a single quote (validate.sh only blocks path traversal), which would
# otherwise break the UPDATE and is an injection surface.
if [ -f "$DB" ]; then
  OLD_LIT=$(agmsg_sqlesc "$OLD_TEAM")
  NEW_LIT=$(agmsg_sqlesc "$NEW_TEAM")
  agmsg_sqlite "$DB" "UPDATE messages SET team='$NEW_LIT' WHERE team='$OLD_LIT';"
  # events may not exist yet on an install that has not sent since the storage
  # flip — best-effort, never abort the rename over a missing optional table.
  agmsg_sqlite "$DB" "UPDATE events SET team='$NEW_LIT' WHERE team='$OLD_LIT';" 2>/dev/null || true
fi

echo "Renamed team $OLD_TEAM → $NEW_TEAM"
echo
echo "Note: existing members in other projects/sessions still see the old"
echo "team name cached. Each member should re-run whoami in their project"
echo "to pick up the new name:"
echo
echo "  ~/.agents/skills/<skill>/scripts/whoami.sh \"\$(pwd)\" <type>"
