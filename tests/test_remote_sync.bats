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
  run grep -l "no echo" "$ENV_B"/bus/events/"$env_b_id".*.jsonl
  [ "$status" -ne 0 ]
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

@test "send: background push reaches the bus" {
  connect_both
  bash "$SCRIPTS/send.sh" testteam alice bob "async push" >/dev/null
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
}
