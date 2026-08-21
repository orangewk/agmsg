#!/usr/bin/env bash
set -euo pipefail

# actas-state.sh — read the live actas ownership state without mutating it.
#
# Usage: actas-state.sh <project> <type> <name> <owner>
#
# Output (stdout, key=value):
#   status=mine team=<team> [team=<team2> ...] owner=<token>
#   status=held team=<team> owner=<token>
#   status=free team=<team>
#   status=not_registered
#   status=unknown
#
# Exit code:
#   0 — status=mine (the supplied composite owner holds every matching team)
#   1 — status=held, status=free, or status=unknown
#   2 — status=not_registered
#
# This is intentionally a query only: unlike claim/session-start flows it does
# not claim, release, or garbage-collect actas locks. A bare owner token is not
# enough to prove per-process ownership, so it is reported as unknown.

PROJECT="${1:?Usage: actas-state.sh <project> <type> <name> <owner>}"
TYPE="${2:?Missing type}"
NAME="${3:?Missing name}"
OWNER="${4:?Missing owner}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

if ! agmsg_instance_is_composite "$OWNER"; then
  echo "status=unknown"
  exit 1
fi

# Match actas-claim.sh's project resolution and roster lookup so callers see
# the same set of (team, name) locks that an actas claim would operate on.
PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"
TEAMS=""
while IFS=$'\t' read -r team agent; do
  [ -z "$team" ] && continue
  [ "$agent" = "$NAME" ] || continue
  TEAMS="${TEAMS:+$TEAMS$'\n'}$team"
done < <("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE")

if [ -z "$TEAMS" ]; then
  echo "status=not_registered"
  exit 2
fi

while IFS= read -r team; do
  [ -z "$team" ] && continue
  state="$(actas_lock_state "$team" "$NAME" "$OWNER")"
  case "$state" in
    mine) ;;
    other:*)
      printf 'status=held team=%s owner=%s\n' "$team" "${state#other:}"
      exit 1
      ;;
    free)
      printf 'status=free team=%s\n' "$team"
      exit 1
      ;;
    *)
      echo "status=unknown"
      exit 1
      ;;
  esac
done <<< "$TEAMS"

printf 'status=mine'
while IFS= read -r team; do
  [ -z "$team" ] && continue
  printf ' team=%s' "$team"
done <<< "$TEAMS"
printf ' owner=%s\n' "$OWNER"
