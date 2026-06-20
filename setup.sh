#!/usr/bin/env bash
set -euo pipefail

# Which ref of the canonical repo to install. The npm bootstrapper
# (bin/agmsg.js) sets AGMSG_REF to the tag matching its own version
# (e.g. v1.0.6) so `npx agmsg@X` installs X — not whatever is on main.
# The README's `curl .../main/setup.sh` form leaves it unset and gets
# main (the latest). See #172.
REF="${AGMSG_REF:-main}"

TMP=$(mktemp -d)
if ! git clone --depth 1 --branch "$REF" https://github.com/fujibee/agmsg.git "$TMP/agmsg" 2>/dev/null; then
  echo "agmsg: failed to clone ref '$REF' from https://github.com/fujibee/agmsg.git" >&2
  rm -rf "$TMP"
  exit 1
fi
"$TMP/agmsg/install.sh" "$@"
rm -rf "$TMP"
