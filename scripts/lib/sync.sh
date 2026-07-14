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
# Read state is replicated as message_read events. Existing writer lines
# without a type remain message_sent for backwards compatibility.
#
# Event classes (ADR 0006): every event type is either a DELIVERABLE (worth
# waking its recipient for) or STATE GOSSIP (converges on the next sync,
# wakes no one). The router on the bus keys its behavior off this table:
#
#   deliverable   message_sent  (and legacy lines with no type)
#   state gossip  message_read
#
# A new event type must declare its class here and in the router.
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

# Rows with id <= cutoff existed before this store was bound to the bus and
# stay local (issue #19). Missing/garbled key (a pre-#19 remote.conf) reads
# as 0 = export everything, the old behavior.
sync_export_cutoff() {
  local c
  c="$(sync_conf_get export_cutoff)"
  case "$c" in ''|*[!0-9]*) c=0 ;; esac
  printf '%s\n' "$c"
}

_sync_git() { git -C "$(sync_bus_dir)" "$@"; }

# Network-touching git ops get a hard wall-clock bound where `timeout` exists
# (Linux, CI, cloud sandboxes): an unroutable host would otherwise hang for
# git's TCP connect timeout, freezing whatever called us — worst on the Stop
# hook. Best-effort: without a timeout binary the ssh ConnectTimeout/BatchMode
# set at `remote add` still bounds the ssh transport.
_sync_net_git() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${AGMSG_SYNC_NET_TIMEOUT:-60}" git -C "$(sync_bus_dir)" "$@"
  else
    git -C "$(sync_bus_dir)" "$@"
  fi
}

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
  agmsg_sqlite "$db" "CREATE TABLE IF NOT EXISTS sync_reads_pending (uuid TEXT PRIMARY KEY, read_at TEXT NOT NULL);"
  agmsg_sqlite "$db" "CREATE TABLE IF NOT EXISTS sync_reads_exported (uuid TEXT PRIMARY KEY, read_at TEXT NOT NULL);"
}

# Mark the currently unread rows for one recipient as read. When the store is
# bound to a remote bus, keep the local read timestamp in a pending table so
# sync_export can emit exactly one message_read event for each local read.
# The pending insert precedes the UPDATE in one transaction; a crash cannot
# leave a read row without its receipt candidate.
sync_mark_read() {
  local db="$1" team_sql="$2" agent_sql="$3"
  sync_migrate "$db" || return 1
  agmsg_sqlite "$db" "
    BEGIN IMMEDIATE;
    INSERT OR IGNORE INTO sync_reads_pending (uuid, read_at)
    SELECT uuid, strftime('%Y-%m-%dT%H:%M:%SZ','now')
    FROM messages
    WHERE team='$team_sql' AND to_agent='$agent_sql'
      AND read_at IS NULL AND uuid IS NOT NULL;
    UPDATE messages
    SET read_at = COALESCE(
      (SELECT read_at FROM sync_reads_pending
       WHERE sync_reads_pending.uuid = messages.uuid),
      strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    WHERE team='$team_sql' AND to_agent='$agent_sql' AND read_at IS NULL;
    COMMIT;"
}

# A read is local UX state, but it must reach the bus without requiring the
# caller to remember a separate remote.sh push. Match send.sh's best-effort
# behavior; tests and callers that need deterministic completion can set
# AGMSG_REMOTE_PUSH_SYNC=1.
sync_push_best_effort() {
  sync_configured || return 0
  if [ "${AGMSG_REMOTE_PUSH_SYNC:-}" = "1" ]; then
    bash "$(_sync_scripts_dir)/remote.sh" push --quiet >/dev/null 2>&1 || true
  else
    (bash "$(_sync_scripts_dir)/remote.sh" push --quiet >/dev/null 2>&1 || true) &
  fi
}

# Throttled best-effort pull for polling loops (monitor-mode watchers). A
# store-level marker shares the cadence across all watchers on this store, so
# N parallel sessions do not each hit the network. Never fails the caller.
#
# The pull runs in a DETACHED background process: a foreground pull against an
# unreachable remote would block the watcher's loop for git's connect timeout
# and stall local delivery with it (PR #18 review P1). The marker (touched
# synchronously, before spawning) throttles spawn rate; the sync lock inside
# sync_op_pull serializes any overlap with other pulls/pushes.
sync_pull_throttled() {
  local interval="${1:-60}" marker now last
  [ -f "$(sync_conf_path)" ] || return 0
  marker="$(agmsg_storage_dir)/.lastpull"
  now=$(date +%s)
  last=$(compat_file_mtime "$marker" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -lt "$interval" ] && return 0
  touch "$marker" 2>/dev/null || true
  (bash "$(_sync_scripts_dir)/remote.sh" pull --quiet >/dev/null 2>&1 || true) &
}

# --- subscriber registry (ADR 0006) -------------------------------------------
# One JSON file per (team, agent) on the bus tells the router who to wake and
# how. The registry lives on the bus because the bus is already the one shared
# place every environment can read and write.

sync_subscriber_path() { printf 'subscribers/%s/%s.json\n' "$1" "$2"; }

# Write (or overwrite) this environment's registration and push it. Emits the
# file's bus path on success. Idempotent: an identical registration is a no-op
# that does not create a commit.
sync_subscribe() {
  local team="$1" agent="$2" pr="$3" bus rel dst body
  bus="$(sync_bus_dir)"
  rel="$(sync_subscriber_path "$team" "$agent")"
  dst="$bus/$rel"
  body=$(printf '{"env":"%s","filter":{"team":"%s","to":"%s"},"wake":{"kind":"pr-comment","pr":%s}}\n' \
    "$(sync_env_id)" "$team" "$agent" "$pr")
  if [ -f "$dst" ] && [ "$(cat "$dst")" = "$(printf '%s' "$body")" ]; then
    printf '%s\n' "$rel"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  printf '%s' "$body" > "$dst"
  _sync_git add "$rel" >/dev/null 2>&1
  _sync_git commit -q -m "subscribe: $team/$agent via pr-comment #$pr" >/dev/null 2>&1 || true
  sync_push_remote || return 1
  printf '%s\n' "$rel"
}

# Remove this (team, agent)'s registration and push. Missing entry is a no-op.
sync_unsubscribe() {
  local team="$1" agent="$2" bus rel
  bus="$(sync_bus_dir)"
  rel="$(sync_subscriber_path "$team" "$agent")"
  [ -f "$bus/$rel" ] || return 0
  _sync_git rm -q "$rel" >/dev/null 2>&1
  _sync_git commit -q -m "unsubscribe: $team/$agent" >/dev/null 2>&1 || true
  sync_push_remote
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

# A team name is safe to use as a bus directory name iff it cannot escape
# events/ or smuggle git options. Mirrors lib/validate.sh's
# agmsg_validate_team_name deny-list EXACTLY (empty, '.', '..', path
# separators, leading '-', control chars) — anything join.sh accepts (UTF-8,
# dotted names like '.foo') must replicate, or its messages would silently
# never leave the machine (PR #18 review). Defense in depth against rows
# written by older versions or by hand; join-validated rows always pass.
_sync_team_pathsafe() {
  case "$1" in
    ''|.|..|*/*|*\\*|-*|*[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# Append never-exported local rows to their team's writer file for this
# environment (events/<team>/<env-id>.<YYYYMM>.jsonl, ADR 0005 layout) and
# commit. Does not touch the network.
sync_export() {
  local db bus env month team team_sql writer tmp_own new_events read_events count total fail cutoff
  db="$(agmsg_db_path)"
  [ -f "$db" ] || return 0
  bus="$(sync_bus_dir)"
  env="$(sync_env_id)"
  month=$(date +%Y%m)
  sync_migrate "$db" || return 1

  cutoff="$(sync_export_cutoff)"

  # Assign ids to never-exported local rows. randomblob() re-evaluates per
  # row; second-precision timestamp + 8 random bytes is collision-safe at
  # this scale and keeps the bus files roughly time-sorted. NOT an export
  # cursor: the writer files are (a uuid-bearing row missing from them is
  # still a candidate), so nothing is stranded if a later step fails.
  # Pre-bind history (id <= cutoff) is left untouched — never exported.
  agmsg_sqlite "$db" "UPDATE messages
    SET uuid = strftime('%Y%m%dT%H%M%SZ','now') || '-' || lower(hex(randomblob(8)))
    WHERE uuid IS NULL AND origin IS NULL AND id > $cutoff;" || return 1

  # Cover rows that were marked read before their first export (for example,
  # a store bound with --include-history). Imported rows have origin set, so
  # this fallback cannot turn a received receipt into an echo.
  agmsg_sqlite "$db" "
    INSERT OR IGNORE INTO sync_reads_pending (uuid, read_at)
    SELECT uuid, read_at FROM messages
    WHERE uuid IS NOT NULL AND read_at IS NOT NULL
      AND origin IS NULL AND id > $cutoff
      AND NOT EXISTS (
        SELECT 1 FROM sync_reads_exported WHERE uuid = messages.uuid);" || return 1

  total=0
  fail=0
  while IFS= read -r team; do
    [ -n "$team" ] || continue
    if ! _sync_team_pathsafe "$team"; then
      echo "agmsg sync: skipping export for path-unsafe team name: $team" >&2
      continue
    fi
    team_sql=$(printf %s "$team" | sed "s/'/''/g")
    mkdir -p "$bus/events/$team"
    writer="$bus/events/$team/$env.$month.jsonl"

    # Everything already in our own writer files for this team (any month)
    # is exported; collapse their lines into one JSON array for the NOT IN.
    tmp_own=$(mktemp)
    # `|| true` inside the group: on first export there are no own files, the
    # glob stays literal and cat fails — that must not kill the pipeline under
    # a caller's pipefail; awk still emits the empty array.
    { cat "$bus/events/$team/$env."*.jsonl 2>/dev/null || true; } \
      | awk 'BEGIN{printf "["} NF{if(n++)printf ","; printf "%s",$0} END{print "]"}' \
      > "$tmp_own"

    # Capture the query's own exit status: callers run us inside an `if`
    # (errexit suppressed), so a sqlite failure here must be aggregated by
    # hand or the op would report success on a store it couldn't read.
    if ! new_events=$(agmsg_sqlite "$db" "
      SELECT json_object(
        'type', 'message_sent', 'id', uuid, 'env', '$env', 'team', team,
        'from', from_agent, 'to', to_agent,
        'body', body, 'created_at', created_at)
      FROM messages
      WHERE origin IS NULL AND uuid IS NOT NULL AND team = '$team_sql'
        AND id > $cutoff
        AND uuid NOT IN (
          SELECT json_extract(value, '\$.id')
          FROM json_each(readfile('$(agmsg_sql_readfile_path "$tmp_own")'))
          WHERE json_extract(value, '\$.id') IS NOT NULL)
      ORDER BY id ASC;"); then
      fail=1
      rm -f "$tmp_own"
      continue
    fi
    # A read event already present in our writer file is exported even if the
    # process died before the bookkeeping row was inserted. This keeps the
    # append-only writer file as the crash-recovery source of truth.
    if ! agmsg_sqlite "$db" "
      INSERT OR IGNORE INTO sync_reads_exported (uuid, read_at)
      SELECT json_extract(value, '\$.ref'), json_extract(value, '\$.at')
      FROM json_each(readfile('$(agmsg_sql_readfile_path "$tmp_own")'))
      WHERE json_extract(value, '\$.type') = 'message_read'
        AND json_extract(value, '\$.ref') IS NOT NULL
        AND json_extract(value, '\$.at') IS NOT NULL;"; then
      fail=1
      rm -f "$tmp_own"
      continue
    fi
    if ! read_events=$(agmsg_sqlite "$db" "
      SELECT json_object(
        'type', 'message_read', 'ref', messages.uuid,
        'at', sync_reads_pending.read_at, 'env', '$env')
      FROM sync_reads_pending
      JOIN messages ON messages.uuid = sync_reads_pending.uuid
      WHERE messages.team = '$team_sql'
        AND NOT EXISTS (
          SELECT 1 FROM sync_reads_exported
          WHERE sync_reads_exported.uuid = sync_reads_pending.uuid)
      ORDER BY messages.id ASC;"); then
      fail=1
      rm -f "$tmp_own"
      continue
    fi
    rm -f "$tmp_own"

    if [ -n "$new_events" ]; then
      printf '%s\n' "$new_events" >> "$writer"
      count=$(printf '%s\n' "$new_events" | wc -l | tr -d ' ')
      total=$(( total + count ))
    fi
    if [ -n "$read_events" ]; then
      if ! printf '%s\n' "$read_events" >> "$writer"; then
        fail=1
        rm -f "$tmp_own"
        continue
      fi
      count=$(printf '%s\n' "$read_events" | wc -l | tr -d ' ')
      total=$(( total + count ))
    fi
  done <<EOF
$(agmsg_sqlite "$db" "
  SELECT DISTINCT team FROM messages
  WHERE uuid IS NOT NULL
    AND (
      (origin IS NULL AND id > $cutoff)
      OR EXISTS (
        SELECT 1 FROM sync_reads_pending
        WHERE sync_reads_pending.uuid = messages.uuid
          AND NOT EXISTS (
            SELECT 1 FROM sync_reads_exported
            WHERE sync_reads_exported.uuid = messages.uuid))
    );")
EOF

  if [ "$total" -gt 0 ]; then
    _sync_git add -A events >/dev/null 2>&1
    _sync_git commit -q -m "sync: $env $total event(s)" >/dev/null 2>&1 || true
  fi
  return "$fail"
}

# Push local bus commits. On a ref race, rebase onto the remote and retry —
# per-writer files mean the rebase itself can never hit a content conflict.
sync_push_remote() {
  local branch attempt
  branch="$(_sync_branch)" || return 1
  for attempt in 1 2 3 4; do
    _sync_net_git push -q -u origin "$branch" >/dev/null 2>&1 && return 0
    _sync_net_git pull --rebase -q origin "$branch" >/dev/null 2>&1 || true
    [ "$attempt" -lt 4 ] && sleep "$attempt"
  done
  return 1
}

# --- pull / import -----------------------------------------------------------

sync_pull_remote() {
  local branch
  branch="$(_sync_branch)" || return 1
  _sync_net_git pull --rebase -q origin "$branch" >/dev/null 2>&1
}

# Load every other environment's writer files into the local store. Purely
# local; call sync_pull_remote first to fetch fresh events.
#
# Reads both the ADR 0005 per-team layout (events/<team>/<env>.jsonl) and the
# flat pre-team layout (events/<env>.jsonl) a v0 exporter may have left on the
# bus. The event's team field is authoritative either way — the path is only
# a namespace.
sync_import() {
  local db bus env f tmp read_file fail
  db="$(agmsg_db_path)"
  [ -f "$db" ] || bash "$(_sync_scripts_dir)/internal/init-db.sh" >/dev/null
  sync_migrate "$db" || return 1
  bus="$(sync_bus_dir)"
  env="$(sync_env_id)"
  fail=0

  # The dot-prefixed globs pick up dotted team dirs like events/.foo/ (a
  # valid join.sh team name) that plain `*` skips; `.[!.]*` and `..?*`
  # together match every dot-name except the `.`/`..` entries themselves.
  for f in "$bus/events/"*.jsonl "$bus/events/"*/*.jsonl \
           "$bus/events/".[!.]*/*.jsonl "$bus/events/"..?*/*.jsonl; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in "$env".*) continue ;; esac
    tmp=$(mktemp)
    awk 'BEGIN{printf "["} NF{if(n++)printf ","; printf "%s",$0} END{print "]"}' "$f" > "$tmp"
    # OR IGNORE + the unique uuid index: rows already imported (or duplicate
    # lines left by a crashed exporter) are skipped, not duplicated. A failed
    # insert (corrupt store, malformed file) is aggregated, not swallowed —
    # callers run inside `if` where errexit cannot see it.
    agmsg_sqlite "$db" "
      INSERT OR IGNORE INTO messages (uuid, origin, team, from_agent, to_agent, body, created_at)
      SELECT json_extract(value, '\$.id'),
             json_extract(value, '\$.env'),
             json_extract(value, '\$.team'),
             json_extract(value, '\$.from'),
             json_extract(value, '\$.to'),
             json_extract(value, '\$.body'),
             json_extract(value, '\$.created_at')
      FROM json_each(readfile('$(agmsg_sql_readfile_path "$tmp")'))
      WHERE COALESCE(json_extract(value, '\$.type'), 'message_sent') = 'message_sent';" || fail=1
    rm -f "$tmp"
  done

  # Read events are applied in a second pass so a receipt is not lost when
  # its message event lives in another writer file that the first pass visits
  # later. The first receipt wins; replaying an older one is harmless.
  for f in "$bus/events/"*.jsonl "$bus/events/"*/*.jsonl \
           "$bus/events/".[!.]*/*.jsonl "$bus/events/"..?*/*.jsonl; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in "$env".*) continue ;; esac
    tmp=$(mktemp)
    awk 'BEGIN{printf "["} NF{if(n++)printf ","; printf "%s",$0} END{print "]"}' "$f" > "$tmp"
    read_file=$(agmsg_sql_readfile_path "$tmp")
    if ! agmsg_sqlite "$db" "
      BEGIN;
      INSERT OR IGNORE INTO sync_reads_exported (uuid, read_at)
      SELECT json_extract(value, '\$.ref'), json_extract(value, '\$.at')
      FROM json_each(readfile('$read_file'))
      WHERE json_extract(value, '\$.type') = 'message_read'
        AND json_extract(value, '\$.ref') IS NOT NULL
        AND json_extract(value, '\$.at') IS NOT NULL;
      UPDATE messages
      SET read_at = (
        SELECT min(json_extract(value, '\$.at'))
        FROM json_each(readfile('$read_file'))
        WHERE json_extract(value, '\$.type') = 'message_read'
          AND json_extract(value, '\$.ref') = messages.uuid
          AND json_extract(value, '\$.at') IS NOT NULL)
      WHERE messages.read_at IS NULL
        AND messages.uuid IN (
        SELECT json_extract(value, '\$.ref')
        FROM json_each(readfile('$read_file'))
        WHERE json_extract(value, '\$.type') = 'message_read'
          AND json_extract(value, '\$.ref') IS NOT NULL
          AND json_extract(value, '\$.at') IS NOT NULL
      );
      COMMIT;"; then
      fail=1
    fi
    rm -f "$tmp"
  done
  return "$fail"
}

# --- top-level operations ----------------------------------------------------
# pull = fetch remote events into the local store (what the Stop hook runs).
# push = export local rows and push them out (what send.sh backgrounds).
#
# Network failures are REPORTED, not swallowed: each op returns non-zero when
# its fetch/push failed, so an explicit `remote.sh push` can tell the user the
# message did not leave the machine (PR #14 review). The state itself is
# always left consistent — events are already committed locally, and the next
# sync catches up. Hook call sites stay best-effort by `|| true`-ing the call.

sync_op_pull() {
  sync_configured || return 0
  sync_lock || return 1
  local rc=0
  _sync_commit_dirty
  sync_pull_remote || rc=1
  sync_import || rc=1
  sync_unlock
  return "$rc"
}

sync_op_push() {
  sync_configured || return 0
  sync_lock || return 1
  local rc=0
  _sync_commit_dirty
  sync_export || rc=1
  sync_push_remote || rc=1
  sync_unlock
  return "$rc"
}

sync_op_sync() {
  sync_configured || return 0
  sync_lock || return 1
  local rc=0
  _sync_commit_dirty
  sync_pull_remote || rc=1
  sync_import || rc=1
  sync_export || rc=1
  sync_push_remote || rc=1
  sync_unlock
  return "$rc"
}
