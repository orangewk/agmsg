#!/usr/bin/env bats

# Public read-only contracts for consumers that must align a hook invocation
# with the same per-process actas owner token used by agmsg itself.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  owner_pid=""
  owner=""
}

teardown() {
  if [ -n "$owner_pid" ]; then
    kill "$owner_pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
  fi
  teardown_test_env
}

fake_register() {
  local team="$1" agent="$2" proj="${3:-/tmp/p1}"
  bash "$SKILL_DIR/scripts/join.sh" "$team" "$agent" claude-code "$proj"
}

start_live_owner() {
  sleep 60 3>&- & owner_pid=$!
  owner="shared-session.$owner_pid"
}

@test "current-instance: returns only a composite owner token" {
  run env AGMSG_AGENT_PID=4242 bash "$SKILL_DIR/scripts/current-instance.sh" claude-code shared-session
  [ "$status" -eq 0 ]
  [ "$output" = "status=ok owner=shared-session.4242" ]
}

@test "current-instance: unresolved agent pid returns unknown, never a bare sid" {
  run env AGMSG_AGENT_PID='' bash "$SKILL_DIR/scripts/current-instance.sh" claude-code shared-session
  [ "$status" -eq 1 ]
  [ "$output" = "status=unknown" ]
}

@test "actas-state: reports mine only when every matching team has this live composite owner" {
  fake_register alpha xipress
  fake_register beta xipress
  start_live_owner
  printf '%s\n' "$owner" > "$RUN_DIR/actas.alpha__xipress.session"
  printf '%s\n' "$owner" > "$RUN_DIR/actas.beta__xipress.session"

  run bash "$SKILL_DIR/scripts/actas-state.sh" /tmp/p1 claude-code xipress "$owner"
  [ "$status" -eq 0 ]
  [ "$output" = "status=mine team=alpha team=beta owner=$owner" ]
}

@test "actas-state: reports the live different owner without changing its lock" {
  fake_register alpha xipress
  start_live_owner
  local lock="$RUN_DIR/actas.alpha__xipress.session"
  printf '%s\n' "$owner" > "$lock"

  run bash "$SKILL_DIR/scripts/actas-state.sh" /tmp/p1 claude-code xipress other-session.4242
  [ "$status" -eq 1 ]
  [ "$output" = "status=held team=alpha owner=$owner" ]
  [ "$(cat "$lock")" = "$owner" ]
}

@test "actas-state: reports free for no lock and rejects a bare owner token" {
  fake_register alpha xipress

  run bash "$SKILL_DIR/scripts/actas-state.sh" /tmp/p1 claude-code xipress missing-lock.4242
  [ "$status" -eq 1 ]
  [ "$output" = "status=free team=alpha" ]

  run bash "$SKILL_DIR/scripts/actas-state.sh" /tmp/p1 claude-code xipress bare-session
  [ "$status" -eq 1 ]
  [ "$output" = "status=unknown" ]
}

@test "actas-state: reports not_registered for an unrelated role" {
  fake_register alpha xipress

  run bash "$SKILL_DIR/scripts/actas-state.sh" /tmp/p1 claude-code unknown shared-session.4242
  [ "$status" -eq 2 ]
  [ "$output" = "status=not_registered" ]
}
