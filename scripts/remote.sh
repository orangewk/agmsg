#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Manage the git-backed remote transport (ADR 0005): replicate messages
# between environments through a private "bus" git repository.
#
# Usage: remote.sh add <git-url> [--include-history] [--env-id <id>]
#                                    configure this store's bus and clone it
#        remote.sh bootstrap <git-url> --team <team> --agent <name> \
#                  [--type <type>] [--project <path>] [--env-id <id>] [--include-history]
#                                    one-shot idempotent setup for ephemeral
#                                    environments: init store, join, add, pull
#        remote.sh status            show bus url, env id, pending counts
#        remote.sh sync              pull + import, then export + push
#        remote.sh pull              fetch remote events into the local store
#        remote.sh push              export local messages and push them out
#        remote.sh remove            forget the bus (local store is untouched)
#
# pull/push/sync accept --quiet (suppress the one-line summary).

ACTION="${1:?Usage: remote.sh add|bootstrap|status|sync|pull|push|remove ...}"
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
    URL="${1:?Usage: remote.sh add <git-url> [--include-history] [--env-id <id>]}"
    shift || true
    INCLUDE_HISTORY=0
    ENV_ID_OVERRIDE="${AGMSG_ENV_ID:-}"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --include-history) INCLUDE_HISTORY=1; shift ;;
        --env-id) ENV_ID_OVERRIDE="${2:?--env-id needs a value}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    require_git
    if sync_configured; then
      # Idempotent re-add: same url (+ same pinned env id, when one is
      # given) is a no-op, so an ephemeral environment's bootstrap script
      # can run add unconditionally on every boot (#15, #17). A different
      # url or env id still requires an explicit remove first.
      if [ "$(sync_remote_url)" = "$URL" ] \
         && { [ -z "$ENV_ID_OVERRIDE" ] || [ "$(sync_env_id)" = "$ENV_ID_OVERRIDE" ]; }; then
        echo "Remote bus already configured: $URL"
        echo "This environment's id: $(sync_env_id)"
        exit 0
      fi
      echo "Remote already configured: $(sync_remote_url) (env_id: $(sync_env_id))" >&2
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
    #
    # A pinned id (--env-id / AGMSG_ENV_ID) lets a regenerated ephemeral
    # environment resume its own writer files instead of littering the bus
    # with one-shot ids (#15). Constraint: at most ONE live instance per
    # pinned id — two concurrent writers on one file would break the
    # per-writer no-conflict guarantee. Sanitized the same way as hostnames.
    if [ -n "$ENV_ID_OVERRIDE" ]; then
      ENV_ID=$(printf '%s' "$ENV_ID_OVERRIDE" | tr -cd 'A-Za-z0-9_-' | cut -c1-48)
      if [ -z "$ENV_ID" ]; then
        echo "Error: --env-id/AGMSG_ENV_ID contains no filename-safe characters" >&2
        rm -rf "$BUS"
        exit 1
      fi
    else
      HOST=$( (hostname 2>/dev/null || uname -n) | tr -cd 'A-Za-z0-9_-' | cut -c1-24)
      [ -n "$HOST" ] || HOST="env"
      ENV_ID="$HOST-$(agmsg_sqlite_mem "SELECT lower(hex(randomblob(3)));")"
    fi

    # Everything already in the store stays local by default: connecting a
    # bus means "share from now on", not "publish my backlog into a permanent
    # git history" (issue #19 — learned the hard way when a first sync pushed
    # 205 unrelated old messages). The cutoff is the highest local row id at
    # bind time; export only takes rows above it. --include-history opts into
    # the old behavior (machine migration, backup).
    CUTOFF=0
    HISTORY_COUNT=0
    DB="$(agmsg_db_path)"
    if [ "$INCLUDE_HISTORY" -ne 1 ] && [ -f "$DB" ]; then
      CUTOFF=$(agmsg_sqlite "$DB" "SELECT COALESCE(MAX(id), 0) FROM messages;" 2>/dev/null || echo 0)
      case "$CUTOFF" in ''|*[!0-9]*) CUTOFF=0 ;; esac
      HISTORY_COUNT=$(agmsg_sqlite "$DB" "SELECT count(*) FROM messages;" 2>/dev/null || echo 0)
    fi

    printf 'url=%s\nenv_id=%s\nexport_cutoff=%s\n' "$URL" "$ENV_ID" "$CUTOFF" > "$STORE_DIR/remote.conf"

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
    if [ "$INCLUDE_HISTORY" -eq 1 ]; then
      echo "Existing local messages WILL be shared (--include-history)"
    elif [ "${HISTORY_COUNT:-0}" -gt 0 ]; then
      echo "$HISTORY_COUNT existing local message(s) will NOT be shared (re-add with --include-history to share them)"
    fi
    ;;

  bootstrap)
    # One line in an ephemeral environment's setup script (SessionStart hook,
    # container boot) replaces the manual join + add + pull dance (#17).
    # Every step is idempotent, so running it on every boot is safe.
    B_URL="${1:?Usage: remote.sh bootstrap <git-url> --team <team> --agent <name> [--type <type>] [--project <path>] [--env-id <id>] [--include-history]}"
    shift || true
    B_TEAM="" B_AGENT="" B_TYPE="claude-code" B_PROJECT="$PWD" B_ENV_ID="${AGMSG_ENV_ID:-}" B_HISTORY=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --team) B_TEAM="${2:?--team needs a value}"; shift 2 ;;
        --agent) B_AGENT="${2:?--agent needs a value}"; shift 2 ;;
        --type) B_TYPE="${2:?--type needs a value}"; shift 2 ;;
        --project) B_PROJECT="${2:?--project needs a value}"; shift 2 ;;
        --env-id) B_ENV_ID="${2:?--env-id needs a value}"; shift 2 ;;
        --include-history) B_HISTORY="--include-history"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$B_TEAM" ] || { echo "Error: bootstrap requires --team" >&2; exit 1; }
    [ -n "$B_AGENT" ] || { echo "Error: bootstrap requires --agent" >&2; exit 1; }
    require_git

    bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null
    # join.sh tolerates re-joins (same name adds a registration, not a dup).
    bash "$SCRIPT_DIR/join.sh" "$B_TEAM" "$B_AGENT" "$B_TYPE" "$B_PROJECT"
    # shellcheck disable=SC2086  # B_HISTORY is deliberately word-split ('' or one flag)
    if [ -n "$B_ENV_ID" ]; then
      bash "$SCRIPT_DIR/remote.sh" add "$B_URL" --env-id "$B_ENV_ID" $B_HISTORY
    else
      bash "$SCRIPT_DIR/remote.sh" add "$B_URL" $B_HISTORY
    fi
    # First pull so anything sent while this environment was dead is already
    # in the store before the first inbox check.
    bash "$SCRIPT_DIR/remote.sh" pull --quiet || echo "Warning: initial pull failed; the next sync catches up" >&2
    echo "Bootstrap complete: $B_AGENT @ $B_TEAM on $B_URL"
    ;;

  status)
    require_configured
    DB="$(agmsg_db_path)"
    PENDING=0
    if [ -f "$DB" ]; then
      sync_migrate "$DB"
      # Pre-bind history (id <= export_cutoff) never exports, so it is not
      # "pending" — counting it would show a forever-stuck backlog (#19).
      PENDING=$(agmsg_sqlite "$DB" "SELECT count(*) FROM messages WHERE uuid IS NULL AND origin IS NULL AND id > $(sync_export_cutoff);")
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
    echo "Unknown action: $ACTION (use add|bootstrap|status|sync|pull|push|remove)" >&2
    exit 1
    ;;
esac
