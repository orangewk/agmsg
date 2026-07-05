#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

@test "status: shows registered agents with delivery modes" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/join.sh" myteam bob codex "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  run bash "$SCRIPTS/status.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg status" ]]
  [[ "$output" =~ $'team\tagent\ttype\tmode\tproject\truntime' ]]
  [[ "$output" =~ $'myteam\talice\tclaude-code\tmonitor' ]]
  [[ "$output" =~ $'myteam\tbob\tcodex\tturn' ]]
}

@test "status: can filter by team" {
  bash "$SCRIPTS/join.sh" alpha alice claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/join.sh" beta bob claude-code "$TEST_PROJECT"

  run bash "$SCRIPTS/status.sh" beta

  [ "$status" -eq 0 ]
  [[ "$output" =~ "beta" ]]
  [[ "$output" =~ "bob" ]]
  [[ ! "$output" =~ "alpha" ]]
  [[ ! "$output" =~ "alice" ]]
}

@test "status: returns non-zero for missing filtered team" {
  run bash "$SCRIPTS/status.sh" missing
  [ "$status" -eq 1 ]
  [[ "$output" =~ "team not found: missing" ]]
}
@test "status: reports rule-file delivery mode" {
  bash "$SCRIPTS/join.sh" myteam gina gemini "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn gemini "$TEST_PROJECT" >/dev/null

  run bash "$SCRIPTS/status.sh" myteam

  [ "$status" -eq 0 ]
  [[ "$output" =~ $'myteam\tgina\tgemini\tturn' ]]
}

