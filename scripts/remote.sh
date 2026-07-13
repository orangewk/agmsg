#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Manage the git-backed remote transport (ADR 0005): replicate messages
# between environments through a private "bus" git repository.
#
# Usage: remote.sh add <git-url>     configure this store's bus and clone it
#        remote.sh status            show bus url, env id, pending counts
#        remote.sh sync              pull + import, then export + push
#        remote.sh pull              fetch remote events into the local store
#        remote.sh push              export local messages and push them out
#        remote.sh remove            forget the bus (local store is untouched)
#
# pull/push/sync accept --quiet (suppress the one-line summary).

ACTION="${1:?Usage: remote.sh add|status|sync|pull|push|remove ...}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/sync.sh"

QUIET=0
for arg in "$@"; do
  [ "$arg" = "--quiet" ] && QUIET=1
done

say() { [ "$QUIET" -eq 1 ] || echo "$1"; }

require_git() {
  command -v git >/dev/null 2>&1 && return 0
  # Same host-agent contract as driver dependency checks: emit a directive
  # the host agent can act on, plus a human-readable line.
  echo 'AGMSG-DIRECTIVE: {"action":"install_dependency","tool":"git","reason":"remote transport requires git"}'
  echo "Error: git is required for the remote transport" >&2
  exit 1
}

require_configured() {
  if ! sync_configured; then
    echo "No remote configured for this store. Run: remote.sh add <git-url>" >&2
    exit 1
  fi
}

case "$ACTION" in
  add)
    URL="${1:?Usage: remote.sh add <git-url>}"
    require_git
    if sync_configured; then
      echo "Remote already configured: $(sync_remote_url)" >&2
      echo "Run 'remote.sh remove' first to rebind." >&2
      exit 1
    fi
    STORE_DIR="$(agmsg_storage_dir)"
    mkdir -p "$STORE_DIR"
    BUS="$(sync_bus_dir)"
    rm -rf "$BUS"
    git clone -q "$URL" "$BUS" 2>/dev/null || { echo "Error: cannot clone $URL" >&2; exit 1; }
    # Commits are made by the sync machinery, not the user; give the clone a
    # self-contained identity and keep bytes exact across platforms.
    git -C "$BUS" config user.name "agmsg"
    git -C "$BUS" config user.email "agmsg@localhost"
    git -C "$BUS" config core.autocrlf false
    # Bound how long a dead network can stall a hook: a stalled HTTP transfer
    # aborts after 20s, and ssh gives up connecting after 10s instead of
    # hanging. BatchMode stops ssh from freezing a hook on an interactive
    # prompt; key/host settings from ~/.ssh/config still apply.
    git -C "$BUS" config http.lowSpeedLimit 1
    git -C "$BUS" config http.lowSpeedTime 20
    git -C "$BUS" config core.sshCommand "ssh -o ConnectTimeout=10 -o BatchMode=yes"

    # Environment id: names this machine's writer files on the bus. Hostname
    # for readability, random suffix for uniqueness (two laptops named
    # "mac.local" must not share a writer file).
    HOST=$( (hostname 2>/dev/null || uname -n) | tr -cd 'A-Za-z0-9_-' | cut -c1-24)
    [ -n "$HOST" ] || HOST="env"
    ENV_ID="$HOST-$(agmsg_sqlite_mem "SELECT lower(hex(randomblob(3)));")"

    printf 'url=%s\nenv_id=%s\n' "$URL" "$ENV_ID" > "$STORE_DIR/remote.conf"

    # A brand-new bus repo has an unborn HEAD; give it a root commit so every
    # later pull/push has a branch to talk about. If that first push is
    # rejected (no write access, protected branch), the binding would never
    # work — roll it back and fail loudly instead of reporting "configured"
    # for a bus this environment cannot write to (PR #18 review).
    if ! git -C "$BUS" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      git -C "$BUS" commit -q --allow-empty -m "init bus"
      if ! git -C "$BUS" push -q -u origin "$(git -C "$BUS" rev-parse --abbrev-ref HEAD)" 2>/dev/null; then
        rm -f "$STORE_DIR/remote.conf"
        rm -rf "$BUS"
        echo "Error: cannot push to $URL (no write access? protected branch?); remote NOT configured" >&2
        exit 1
      fi
    fi
    echo "Remote bus configured: $URL"
    echo "This environment's id: $ENV_ID"
    ;;

  status)
    require_configured
    DB="$(agmsg_db_path)"
    PENDING=0
    if [ -f "$DB" ]; then
      sync_migrate "$DB"
      PENDING=$(agmsg_sqlite "$DB" "SELECT count(*) FROM messages WHERE uuid IS NULL AND origin IS NULL;")
    fi
    AHEAD=$(git -C "$(sync_bus_dir)" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    echo "url: $(sync_remote_url)"
    echo "env_id: $(sync_env_id)"
    echo "unexported messages: $PENDING"
    echo "unpushed commits: $AHEAD"
    ;;

  pull)
    require_configured
    require_git
    trap sync_unlock EXIT
    if sync_op_pull; then
      say "Pulled remote events into the local store"
    else
      echo "Error: could not fetch from the remote bus (offline? credentials?)." >&2
      echo "Already-fetched events were imported; the rest arrive on the next successful pull." >&2
      exit 1
    fi
    ;;

  push)
    require_configured
    require_git
    trap sync_unlock EXIT
    if sync_op_push; then
      say "Exported and pushed local messages"
    else
      echo "Error: could not push to the remote bus (offline? credentials? protected branch?)." >&2
      echo "Messages are committed locally and will be pushed by the next successful push/sync." >&2
      exit 1
    fi
    ;;

  sync)
    require_configured
    require_git
    trap sync_unlock EXIT
    if sync_op_sync; then
      say "Synced with remote bus"
    else
      echo "Error: sync with the remote bus failed (offline? credentials?)." >&2
      echo "Local state is consistent; the next successful sync catches up." >&2
      exit 1
    fi
    ;;

  remove)
    require_configured
    rm -f "$(sync_conf_path)"
    rm -rf "$(sync_bus_dir)"
    echo "Remote bus removed (local messages kept)"
    ;;

  *)
    echo "Unknown action: $ACTION (use add|status|sync|pull|push|remove)" >&2
    exit 1
    ;;
esac
