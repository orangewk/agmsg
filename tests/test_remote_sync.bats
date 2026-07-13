#!/usr/bin/env bats
# Remote transport (ADR 0005): replicate messages between environments
# through a git "bus" repository. The bus here is a local bare repo, and a
# second environment is simulated by pointing AGMSG_STORAGE_PATH at a second
# store — same mechanics as two machines pushing to the same GitHub repo,
# minus the network.

load test_helper

setup() {
  setup_test_env
  command -v git >/dev/null 2>&1 || skip "git not installed"

  git init -q --bare "$TEST_SKILL_DIR/bus.git"

  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b

  # Environment B: a second message store sharing the same scripts/teams.
  export ENV_B="$TEST_SKILL_DIR/db-b"
  mkdir -p "$ENV_B"

  # Push synchronously: send.sh's default background push races teardown's
  # rm -rf of the store (observed as "Directory not empty" on CI). The one
  # test exercising the background path opts back out explicitly.
  export AGMSG_REMOTE_PUSH_SYNC=1
}

teardown() {
  teardown_test_env
}

# Run a script against environment B's store.
in_b() { AGMSG_STORAGE_PATH="$ENV_B" bash "$@"; }

connect_both() {
  bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  in_b "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
}

# --- remote.sh add / status / remove ---

@test "remote add: writes conf, clones bus, assigns env id" {
  run bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Remote bus configured" ]]
  [ -f "$TEST_SKILL_DIR/db/remote.conf" ]
  [ -d "$TEST_SKILL_DIR/db/bus/.git" ]
  grep -q '^env_id=' "$TEST_SKILL_DIR/db/remote.conf"
}

@test "remote add: refuses to rebind without remove" {
  bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  run bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "already configured" ]]
}

@test "remote status: reports url and pending counts" {
  bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  bash "$SCRIPTS/send.sh" testteam alice bob "pending" >/dev/null
  run bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" =~ "url: " ]]
  [[ "$output" =~ "env_id: " ]]
}

@test "remote remove: forgets bus but keeps local messages" {
  bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  bash "$SCRIPTS/send.sh" testteam alice bob "keep me" >/dev/null
  bash "$SCRIPTS/remote.sh" remove
  [ ! -f "$TEST_SKILL_DIR/db/remote.conf" ]
  [ ! -d "$TEST_SKILL_DIR/db/bus" ]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "keep me" ]]
}

@test "remote sync: fails cleanly when unconfigured" {
  run bash "$SCRIPTS/remote.sh" sync
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No remote configured" ]]
}

# --- cross-environment delivery ---

@test "sync: a message crosses environments" {
  connect_both
  bash "$SCRIPTS/send.sh" testteam alice bob "hello from A" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  in_b "$SCRIPTS/remote.sh" sync
  run in_b "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello from A" ]]
  [[ "$output" =~ "alice" ]]
}

@test "sync: repeated syncs never duplicate a message" {
  connect_both
  bash "$SCRIPTS/send.sh" testteam alice bob "once only" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  bash "$SCRIPTS/remote.sh" sync
  in_b "$SCRIPTS/remote.sh" sync
  in_b "$SCRIPTS/remote.sh" sync
  bash "$SCRIPTS/remote.sh" sync

  count_a=$(sqlite_mem_db "$TEST_SKILL_DIR/db/messages.db")
  count_b=$(sqlite_mem_db "$ENV_B/messages.db")
  [ "$count_a" = "1" ]
  [ "$count_b" = "1" ]
}

# Count "once only" rows in a store (helper for the dedupe test above).
sqlite_mem_db() {
  sqlite3 "$1" "SELECT count(*) FROM messages WHERE body='once only';" | tr -d '\r'
}

@test "sync: concurrent writers converge after a push race" {
  connect_both
  # Both environments write before either pushes: B's push lands second and
  # must rebase over A's — per-writer files make that conflict-free.
  bash "$SCRIPTS/send.sh" testteam alice bob "from A" >/dev/null
  in_b "$SCRIPTS/send.sh" testteam bob alice "from B" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  in_b "$SCRIPTS/remote.sh" sync
  bash "$SCRIPTS/remote.sh" sync

  run bash "$SCRIPTS/inbox.sh" testteam alice
  [[ "$output" =~ "from B" ]]
  run in_b "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "from A" ]]
}

@test "sync: message body with newlines and quotes round-trips" {
  connect_both
  BODY=$'line one\nline "two"\ttabbed'
  bash "$SCRIPTS/send.sh" testteam alice bob "$BODY" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  in_b "$SCRIPTS/remote.sh" sync
  got=$(sqlite3 "$ENV_B/messages.db" "SELECT body FROM messages WHERE from_agent='alice';" | tr -d '\r')
  [ "$got" = "$(printf '%s' "$BODY" | tr -d '\r')" ]
}

@test "sync: imported rows do not echo back onto the bus" {
  connect_both
  bash "$SCRIPTS/send.sh" testteam alice bob "no echo" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  in_b "$SCRIPTS/remote.sh" sync   # B imports, then exports its own (none)
  # B's writer files must not contain A's event.
  env_b_id=$(sed -n 's/^env_id=//p' "$ENV_B/remote.conf")
  run grep -l "no echo" "$ENV_B"/bus/events/testteam/"$env_b_id".*.jsonl
  [ "$status" -ne 0 ]
}

@test "sync: writer files use the per-team ADR 0005 namespace" {
  connect_both
  bash "$SCRIPTS/send.sh" testteam alice bob "namespaced" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  env_a_id=$(sed -n 's/^env_id=//p' "$TEST_SKILL_DIR/db/remote.conf")
  run grep -l "namespaced" "$TEST_SKILL_DIR"/db/bus/events/testteam/"$env_a_id".*.jsonl
  [ "$status" -eq 0 ]
}

@test "sync: legacy flat writer files on the bus still import" {
  connect_both
  # A v0 exporter left a flat events/<env>.jsonl on the bus; hand-plant one.
  flat="$TEST_SKILL_DIR/db/bus/events/legacy-env.202607.jsonl"
  mkdir -p "$(dirname "$flat")"
  printf '%s\n' '{"id":"legacy-0001","env":"legacy-env","team":"testteam","from":"alice","to":"bob","body":"from the flat past","created_at":"2026-07-01T00:00:00Z"}' > "$flat"
  git -C "$TEST_SKILL_DIR/db/bus" add -A events
  git -C "$TEST_SKILL_DIR/db/bus" commit -qm "legacy event"
  git -C "$TEST_SKILL_DIR/db/bus" push -q origin HEAD
  in_b "$SCRIPTS/remote.sh" sync
  run in_b "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "from the flat past" ]]
}

@test "push: a failing remote surfaces a non-zero exit (not a false 'pushed')" {
  bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  git -C "$TEST_SKILL_DIR/db/bus" remote set-url origin "$TEST_SKILL_DIR/nonexistent.git"
  bash "$SCRIPTS/send.sh" testteam alice bob "stranded" >/dev/null 2>&1 || true
  run bash "$SCRIPTS/remote.sh" push
  [ "$status" -ne 0 ]
  [[ "$output" =~ "could not push" ]]
  # The message survived locally and pushes once the remote heals.
  git -C "$TEST_SKILL_DIR/db/bus" remote set-url origin "$TEST_SKILL_DIR/bus.git"
  run bash "$SCRIPTS/remote.sh" push
  [ "$status" -eq 0 ]
  run git -C "$TEST_SKILL_DIR/bus.git" grep -q "stranded" HEAD --
  [ "$status" -eq 0 ]
}

@test "sync: a failing remote surfaces a non-zero exit" {
  bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  git -C "$TEST_SKILL_DIR/db/bus" remote set-url origin "$TEST_SKILL_DIR/nonexistent.git"
  run bash "$SCRIPTS/remote.sh" sync
  [ "$status" -ne 0 ]
}

@test "pull: a corrupt local store surfaces a non-zero exit" {
  connect_both
  bash "$SCRIPTS/send.sh" testteam alice bob "seed" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  # B's store becomes garbage AFTER events land on the bus; import must fail
  # loudly, not report a successful pull over a store it couldn't write.
  printf 'not a sqlite database' > "$ENV_B/messages.db"
  run in_b "$SCRIPTS/remote.sh" pull
  [ "$status" -ne 0 ]
}

@test "add: a bus that rejects the initial push is not left configured" {
  git init -q --bare "$TEST_SKILL_DIR/readonly.git"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_SKILL_DIR/readonly.git/hooks/pre-receive"
  chmod +x "$TEST_SKILL_DIR/readonly.git/hooks/pre-receive"
  run bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/readonly.git"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "NOT configured" ]]
  [ ! -f "$TEST_SKILL_DIR/db/remote.conf" ]
  [ ! -d "$TEST_SKILL_DIR/db/bus" ]
}

@test "sync: a dotted team name join.sh accepts ('.foo') replicates" {
  bash "$SCRIPTS/join.sh" .foo alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" .foo bob claude-code /tmp/project-b
  connect_both
  bash "$SCRIPTS/send.sh" .foo alice bob "dotted team" >/dev/null
  bash "$SCRIPTS/remote.sh" sync
  # The event reached the bus under the dotted team dir...
  env_a_id=$(sed -n 's/^env_id=//p' "$TEST_SKILL_DIR/db/remote.conf")
  run grep -l "dotted team" "$TEST_SKILL_DIR"/db/bus/events/.foo/"$env_a_id".*.jsonl
  [ "$status" -eq 0 ]
  # ...and the other environment imports it (dot-dir glob coverage).
  in_b "$SCRIPTS/remote.sh" sync
  run in_b "$SCRIPTS/inbox.sh" .foo bob
  [[ "$output" =~ "dotted team" ]]
}

# --- hook integration ---

@test "inbox: pulls remote messages before reading" {
  connect_both
  in_b "$SCRIPTS/send.sh" testteam bob alice "pulled by inbox" >/dev/null
  in_b "$SCRIPTS/remote.sh" sync
  # No explicit sync in A — inbox.sh's own pull must fetch it.
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pulled by inbox" ]]
}

@test "check-inbox: delivers a remote message via the pull hook" {
  connect_both
  in_b "$SCRIPTS/send.sh" testteam bob alice "remote ping" >/dev/null
  in_b "$SCRIPTS/remote.sh" sync
  run bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "decision" ]]
  [[ "$output" =~ "remote ping" ]]
}

@test "watch: monitor-mode watcher pulls remote messages into its stream" {
  skip_on_windows "watcher process semantics (#134)"
  connect_both
  # Deliberately via config.sh, not the env override: pins that the parser's
  # set→get round trip works for this three-part dotted key (PR #18 review).
  bash "$SCRIPTS/config.sh" set delivery.monitor.remote_pull_interval 1 >/dev/null
  [ "$(bash "$SCRIPTS/config.sh" get delivery.monitor.remote_pull_interval 60)" = "1" ]
  out="$TEST_SKILL_DIR/watch.out"
  AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" watchsess /tmp/project-a claude-code > "$out" 2>/dev/null &
  WPID=$!
  # Message originates in the OTHER environment after the watcher started;
  # only the watcher's own remote pull can deliver it (no hook runs here).
  in_b "$SCRIPTS/send.sh" testteam bob alice "monitor pull" >/dev/null
  in_b "$SCRIPTS/remote.sh" sync
  found=1
  for _ in $(seq 1 40); do
    if grep -q "monitor pull" "$out" 2>/dev/null; then
      found=0
      break
    fi
    sleep 0.5
  done
  kill "$WPID" 2>/dev/null || true
  wait "$WPID" 2>/dev/null || true
  [ "$found" -eq 0 ]
}

@test "watch: an unreachable remote does not stall local delivery" {
  skip_on_windows "watcher process semantics (#134)"
  bash "$SCRIPTS/remote.sh" add "$TEST_SKILL_DIR/bus.git"
  # Non-routable address: connects hang (or die at the net timeout) instead
  # of failing fast, which is exactly the case that used to block the loop.
  git -C "$TEST_SKILL_DIR/db/bus" remote set-url origin "http://10.255.255.1/hang.git"
  out="$TEST_SKILL_DIR/watch.out"
  AGMSG_WATCH_INTERVAL=1 AGMSG_REMOTE_PULL_INTERVAL=1 AGMSG_SYNC_NET_TIMEOUT=5 \
    bash "$SCRIPTS/watch.sh" watchsess2 /tmp/project-a claude-code > "$out" 2>/dev/null &
  WPID=$!
  # Wait for the watcher's watermark before sending: a message that lands
  # before the mark is set counts as history and is (correctly) not streamed.
  for _ in $(seq 1 30); do
    ls "$TEST_SKILL_DIR/run/"watch.*.watermark >/dev/null 2>&1 && break
    sleep 0.5
  done
  # A LOCAL message (send's own push backgrounds; it must not block either).
  AGMSG_REMOTE_PUSH_SYNC= bash "$SCRIPTS/send.sh" testteam bob alice "local while offline" >/dev/null
  found=1
  for _ in $(seq 1 30); do
    if grep -q "local while offline" "$out" 2>/dev/null; then
      found=0
      break
    fi
    sleep 0.5
  done
  kill "$WPID" 2>/dev/null || true
  wait "$WPID" 2>/dev/null || true
  [ "$found" -eq 0 ]
}

@test "send: background push reaches the bus" {
  connect_both
  AGMSG_REMOTE_PUSH_SYNC= bash "$SCRIPTS/send.sh" testteam alice bob "async push" >/dev/null
  # send.sh pushes in the background; poll the bare repo until the event
  # lands (bounded — ~10s worst case on a local filesystem is generous).
  found=1
  for _ in $(seq 1 20); do
    if git -C "$TEST_SKILL_DIR/bus.git" grep -q "async push" HEAD -- 2>/dev/null; then
      found=0
      break
    fi
    sleep 0.5
  done
  [ "$found" -eq 0 ]
  # Let the background pusher finish (it releases the sync lock as it exits)
  # so teardown's rm -rf doesn't race its last writes.
  for _ in $(seq 1 20); do
    [ ! -d "$TEST_SKILL_DIR/db/bus.lock" ] && break
    sleep 0.5
  done
}
