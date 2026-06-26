#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "roster: lists team agent names" {
  bash "$SCRIPTS/join.sh" myteam ada claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam noether codex /tmp/proj-b
  run bash -c "source '$SCRIPTS/lib/roster.sh'; agmsg_roster_names myteam"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ada" ]]
  [[ "$output" =~ "noether" ]]
}

@test "roster: missing team is empty and successful" {
  run bash -c "source '$SCRIPTS/lib/roster.sh'; agmsg_roster_names nope"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "roster: suggestions are safe with empty roster under set -u" {
  run bash -c "set -u; source '$SCRIPTS/lib/roster.sh'; agmsg_suggest_names emptyteam 5"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 5 ]
}

@test "whoami: first run with no teams includes suggested names" {
  run bash "$SCRIPTS/whoami.sh" /tmp/first-project claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ "$output" =~ "available_teams=none" ]]
  [[ "$output" =~ "suggested=" ]]
  [[ "$output" =~ suggested=[^[:space:]]+ ]]
}
@test "roster: suggestions do not collide with existing roster names" {
  bash "$SCRIPTS/join.sh" myteam ada claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam lovelace codex /tmp/proj-b
  run bash -c "source '$SCRIPTS/lib/roster.sh'; agmsg_suggest_names myteam 5"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ (^|[[:space:]])ada($|[[:space:]]) ]]
  [[ ! "$output" =~ (^|[[:space:]])lovelace($|[[:space:]]) ]]
  [ "$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 5 ]
}

@test "roster: suggestions are deterministic for the same roster" {
  bash "$SCRIPTS/join.sh" myteam ada claude-code /tmp/proj-a
  first="$(bash -c "source '$SCRIPTS/lib/roster.sh'; agmsg_suggest_names myteam 5")"
  second="$(bash -c "source '$SCRIPTS/lib/roster.sh'; agmsg_suggest_names myteam 5")"
  [ "$first" = "$second" ]
}

@test "roster: suggestions use clean identity names" {
  run bash -c "source '$SCRIPTS/lib/roster.sh'; agmsg_suggest_names myteam 10"
  [ "$status" -eq 0 ]
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [[ "$name" =~ ^[a-z0-9-]+$ ]]
    [ "$name" != "codex" ]
    [ "$name" != "cc" ]
  done <<< "$output"
}

@test "whoami: not_joined includes roster-aware suggested names" {
  bash "$SCRIPTS/join.sh" myteam ada claude-code /tmp/other
  run bash "$SCRIPTS/whoami.sh" /tmp/new-project claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ "$output" =~ "suggested=" ]]
  [[ ! "$output" =~ "suggested=ada" ]]
}

@test "whoami: reuse suggestions also include unused suggested names" {
  bash "$SCRIPTS/join.sh" myteam ada claude-code /tmp/proj-a
  run bash "$SCRIPTS/whoami.sh" /tmp/proj-b claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "suggest=true" ]]
  [[ "$output" =~ "agents=ada" ]]
  [[ "$output" =~ "suggested=" ]]
  [[ ! "$output" =~ "suggested=ada" ]]
}
