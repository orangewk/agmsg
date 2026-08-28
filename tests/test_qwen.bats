#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_PROJECT/.qwen"
}

teardown() { teardown_test_env; }

json_value() {
  local path="$1" query="$2"
  sqlite_mem "SELECT json_extract(readfile('$(rf "$path")'), '$query');"
}

@test "qwen manifest declares interactive spawn and turn delivery" {
  source "$SCRIPTS/lib/type-registry.sh"
  local values
  values="$(agmsg_type_get qwen cli)|$(agmsg_type_get qwen prompt_arg)|$(agmsg_type_get qwen model_arg)|$(agmsg_type_get qwen hooks_file)|$(agmsg_type_get qwen delivery_modes)"
  [ "$values" = "qwen|-i|-m|.qwen/settings.json|turn off" ]
}

@test "qwen turn delivery preserves settings and adds a Qwen Stop hook" {
  cat >"$TEST_PROJECT/.qwen/settings.json" <<'JSON'
{"theme":"dark","hooks":{"Stop":[{"matcher":"keep","hooks":[{"type":"command","command":"echo keep"}]}]}}
JSON

  run bash "$SCRIPTS/delivery.sh" set turn qwen "$TEST_PROJECT"
  [ "$status" -eq 0 ]

  local settings="$TEST_PROJECT/.qwen/settings.json"
  [ "$(json_value "$settings" '$.theme')" = "dark" ]
  [ "$(json_value "$settings" '$.hooks.Stop[0].hooks[0].command')" = "echo keep" ]
  [[ "$(json_value "$settings" '$.hooks.Stop[1].hooks[0].command')" == node*qwen/hook.mjs* ]]
  if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
    local command="$(json_value "$settings" '$.hooks.Stop[1].hooks[0].command')"
    [ "$(json_value "$settings" '$.hooks.Stop[1].hooks[0].shell')" = "powershell" ]
    [[ "$command" == node\ \'[A-Za-z]:/* ]]
  fi
}

@test "qwen off removes only the agmsg hook" {
  bash "$SCRIPTS/delivery.sh" set turn qwen "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" set off qwen "$TEST_PROJECT"
  [ "$status" -eq 0 ]

  local settings="$TEST_PROJECT/.qwen/settings.json"
  [ "$(json_value "$settings" '$.hooks.Stop')" = "" ]
}

@test "qwen rejects monitor and both before writing settings" {
  local mode
  for mode in monitor both; do
    run bash "$SCRIPTS/delivery.sh" set "$mode" qwen "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not supported for qwen"* ]]
  done
  [ ! -e "$TEST_PROJECT/.qwen/settings.json" ]
}

@test "qwen hook wrapper has valid JavaScript syntax" {
  run node --check "$SCRIPTS/drivers/types/qwen/hook.mjs"
  [ "$status" -eq 0 ]
}

@test "spawn qwen uses -i and keeps the task in the initial prompt" {
  local stub="$BATS_TEST_TMPDIR/bin"
  local capture="$BATS_TEST_TMPDIR/boot-path.txt"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/qwen"
  chmod +x "$stub/qwen"

  bash "$SCRIPTS/join.sh" myteam coordinator claude-code "$TEST_PROJECT"
  run env PATH="$stub:$PATH" \
    bash "$SCRIPTS/spawn.sh" qwen qwen-worker \
      --project "$TEST_PROJECT" \
      --team myteam \
      --model qwen3-coder-plus \
      --boot-prompt "send QWEN-SPAWN-OK to coordinator" \
      --terminal "printf '%s' {cmd} > '$capture'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping readiness wait"* ]]

  local boot
  boot="$(cat "$capture")"
  run cat "$boot"
  [[ "$output" == *"qwen -m qwen3-coder-plus -i"* ]]
  local skill_name; skill_name="$(basename "$TEST_SKILL_DIR")"
  [[ "$output" == *"Use the $skill_name skill to act as qwen-worker"* ]]
  [[ "$output" == *"send QWEN-SPAWN-OK to coordinator"* ]]
}
