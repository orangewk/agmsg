#!/usr/bin/env bash
# sync.sh — git-backed remote transport for the message store (ADR 0005 MVP).
#
# Replicates locally-created rows of the `messages` table through a private
# "bus" git repository as append-only, per-environment JSONL writer files:
#
#   events/<env-id>.<YYYYMM>.jsonl
#
# Each environment appends only to its own files, so two environments can
# never produce a content conflict — pushes race only on the ref, and a
# fetch+rebase retry loop resolves that mechanically. Import is a
# union-by-uuid (INSERT OR IGNORE against a unique index), so replaying any
# file any number of times is idempotent.
#
# State added to the sqlite store (nullable columns; legacy rows and
# stores without a remote are unaffected):
#
#   uuid   — global event id. NULL until first export for local rows;
#            always set on imported rows. Doubles as the export cursor:
#            a local row with uuid IS NULL has never been exported.
#   origin — env-id of the environment that created the row; NULL for
#            locally-created rows. Export selects `origin IS NULL`, so
#            imported events never echo back onto the bus.
#
# The writer files themselves are the record of what was already appended
# (crash-safe: an append that didn't reach its commit is still visible in
# the working tree, and a duplicate line is neutralized by import's
# INSERT OR IGNORE on the other side).
#
# Read state (read_at) is deliberately NOT replicated in the MVP: each
# environment keeps its own read cursor, so an agent joined in two
# environments sees the message in both. See docs/remote.md.
#
# Callers must source lib/storage.sh and lib/compat.sh first.

sync_conf_path() { printf '%s/remote.conf\n' "$(agmsg_storage_dir)"; }
sync_bus_dir() { printf '%s/bus\n' "$(agmsg_storage_dir)"; }

sync_configured() { [ -f "$(sync_conf_path)" ] && [ -d "$(sync_bus_dir)/.git" ]; }

# Parse (never source) remote.conf: KEY=VALUE, one per line.
sync_conf_get() {
  sed -n "s/^$1=//p" "$(sync_conf_path)" 2>/dev/null | head -1
}

sync_env_id() { sync_conf_get env_id; }
sync_remote_url() { sync_conf_get url; }

_sync_git() { git -C "$(sync_bus_dir)" "$@"; }

_sync_branch() { _sync_git rev-parse --abbrev-ref HEAD 2>/dev/null; }

# scripts/ dir, resolved from this file (lib/..). SKILL_DIR fallback mirrors
# storage.sh: Claude Code sandbox runs Bash via pipe/eval, leaving BASH_SOURCE
# empty while the calling script's $0 (and thus SKILL_DIR) is populated.
_sync_scripts_dir() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  elif [ -n "${SKILL_DIR:-}" ]; then
    printf '%s/scripts\n' "$SKILL_DIR"
  else
    echo "Error: cannot resolve scripts dir (BASH_SOURCE and SKILL_DIR both empty)" >&2
    return 1
  fi
}

# --- locking -----------------------------------------------------------------
# One sync at a time per store. mkdir is the portable atomic primitive (same
# reasoning as lib/registry-lock.sh). A lock older than 10 minutes is presumed
# leaked by a killed sync and stolen; a healthy sync holds it for seconds.

sync_lock() {
  local lock tries age now
  lock="$(agmsg_storage_dir)/bus.lock"
  tries=0
  until mkdir "$lock" 2>/dev/null; do
    now=$(date +%s)
    age=$(( now - $(compat_file_mtime "$lock" 2>/dev/null || echo "$now") ))
    if [ "$age" -gt 600 ]; then
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -ge 20 ] && return 1
    sleep 1
  done
  _SYNC_LOCK="$lock"
}

sync_unlock() {
  [ -n "${_SYNC_LOCK:-}" ] && rmdir "$_SYNC_LOCK" 2>/dev/null
  _SYNC_LOCK=""
  return 0
}

# --- schema ------------------------------------------------------------------

# Idempotent: add the sync columns and the dedupe index to an existing store.
sync_migrate() {
  local db="$1" cols
  cols=$(agmsg_sqlite "$db" "PRAGMA table_info(messages);" | cut -d'|' -f2)
  printf '%s\n' "$cols" | grep -qx uuid \
    || agmsg_sqlite "$db" "ALTER TABLE messages ADD COLUMN uuid TEXT;"
  printf '%s\n' "$cols" | grep -qx origin \
    || agmsg_sqlite "$db" "ALTER TABLE messages ADD COLUMN origin TEXT;"
  agmsg_sqlite "$db" "CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_uuid ON messages(uuid) WHERE uuid IS NOT NULL;"
}

# --- export / push -----------------------------------------------------------

# Commit any leftover working-tree state from a sync that died between append
# and commit, so the pull --rebase below never trips over a dirty tree.
_sync_commit_dirty() {
  if [ -n "$(_sync_git status --porcelain 2>/dev/null)" ]; then
    _sync_git add -A >/dev/null 2>&1
    _sync_git commit -q -m "sync: $(sync_env_id) recover" >/dev/null 2>&1 || true
  fi
}

# Append never-exported local rows to this environment's writer file and
# commit. Does not touch the network.
sync_export() {
  local db bus env writer tmp_own new_events count
  db="$(agmsg_db_path)"
  [ -f "$db" ] || return 0
  bus="$(sync_bus_dir)"
  env="$(sync_env_id)"
  sync_migrate "$db"

  # Assign ids to never-exported local rows. randomblob() re-evaluates per
  # row; second-precision timestamp + 8 random bytes is collision-safe at
  # this scale and keeps the bus files roughly time-sorted.
  agmsg_sqlite "$db" "UPDATE messages
    SET uuid = strftime('%Y%m%dT%H%M%SZ','now') || '-' || lower(hex(randomblob(8)))
    WHERE uuid IS NULL AND origin IS NULL;"

  mkdir -p "$bus/events"
  writer="$bus/events/$env.$(date +%Y%m).jsonl"

  # Everything already in our own writer files (any month) is exported;
  # collapse their lines into one JSON array for the NOT IN below.
  tmp_own=$(mktemp)
  # `|| true` inside the group: on first export there are no own files, the
  # glob stays literal and cat fails — that must not kill the pipeline under
  # a caller's pipefail; awk still emits the empty array.
  { cat "$bus/events/$env."*.jsonl 2>/dev/null || true; } \
    | awk 'BEGIN{printf "["} NF{if(n++)printf ","; printf "%s",$0} END{print "]"}' \
    > "$tmp_own"

  new_events=$(agmsg_sqlite "$db" "
    SELECT json_object(
      'id', uuid, 'env', '$env', 'team', team,
      'from', from_agent, 'to', to_agent,
      'body', body, 'created_at', created_at)
    FROM messages
    WHERE origin IS NULL AND uuid IS NOT NULL
      AND uuid NOT IN (
        SELECT json_extract(value, '\$.id')
        FROM json_each(readfile('$(agmsg_sql_readfile_path "$tmp_own")')))
    ORDER BY id ASC;")
  rm -f "$tmp_own"

  if [ -n "$new_events" ]; then
    printf '%s\n' "$new_events" >> "$writer"
    count=$(printf '%s\n' "$new_events" | wc -l | tr -d ' ')
    _sync_git add -A events >/dev/null 2>&1
    _sync_git commit -q -m "sync: $env $count event(s)" >/dev/null 2>&1 || true
  fi
}

# Push local bus commits. On a ref race, rebase onto the remote and retry —
# per-writer files mean the rebase itself can never hit a content conflict.
sync_push_remote() {
  local branch attempt
  branch="$(_sync_branch)" || return 1
  for attempt in 1 2 3 4; do
    _sync_git push -q -u origin "$branch" >/dev/null 2>&1 && return 0
    _sync_git pull --rebase -q origin "$branch" >/dev/null 2>&1 || true
    [ "$attempt" -lt 4 ] && sleep "$attempt"
  done
  return 1
}

# --- pull / import -----------------------------------------------------------

sync_pull_remote() {
  local branch
  branch="$(_sync_branch)" || return 1
  _sync_git pull --rebase -q origin "$branch" >/dev/null 2>&1
}

# Load every other environment's writer files into the local store. Purely
# local; call sync_pull_remote first to fetch fresh events.
sync_import() {
  local db bus env f tmp
  db="$(agmsg_db_path)"
  [ -f "$db" ] || bash "$(_sync_scripts_dir)/internal/init-db.sh" >/dev/null
  sync_migrate "$db"
  bus="$(sync_bus_dir)"
  env="$(sync_env_id)"

  for f in "$bus/events/"*.jsonl; do
    [ -e "$f" ] || break
    case "$(basename "$f")" in "$env".*) continue ;; esac
    tmp=$(mktemp)
    awk 'BEGIN{printf "["} NF{if(n++)printf ","; printf "%s",$0} END{print "]"}' "$f" > "$tmp"
    # OR IGNORE + the unique uuid index: rows already imported (or duplicate
    # lines left by a crashed exporter) are skipped, not duplicated.
    agmsg_sqlite "$db" "
      INSERT OR IGNORE INTO messages (uuid, origin, team, from_agent, to_agent, body, created_at)
      SELECT json_extract(value, '\$.id'),
             json_extract(value, '\$.env'),
             json_extract(value, '\$.team'),
             json_extract(value, '\$.from'),
             json_extract(value, '\$.to'),
             json_extract(value, '\$.body'),
             json_extract(value, '\$.created_at')
      FROM json_each(readfile('$(agmsg_sql_readfile_path "$tmp")'));"
    rm -f "$tmp"
  done
}

# --- top-level operations ----------------------------------------------------
# pull = fetch remote events into the local store (what the Stop hook runs).
# push = export local rows and push them out (what send.sh backgrounds).
# Both are best-effort on the network: offline leaves everything consistent
# and the next sync catches up.

sync_op_pull() {
  sync_configured || return 0
  sync_lock || return 1
  _sync_commit_dirty
  sync_pull_remote || true
  sync_import
  sync_unlock
}

sync_op_push() {
  sync_configured || return 0
  sync_lock || return 1
  _sync_commit_dirty
  sync_export
  sync_push_remote || true
  sync_unlock
}

sync_op_sync() {
  sync_configured || return 0
  sync_lock || return 1
  _sync_commit_dirty
  sync_pull_remote || true
  sync_import
  sync_export
  sync_push_remote || true
  sync_unlock
}
