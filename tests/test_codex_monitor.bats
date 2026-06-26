#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export CALL_LOG="$TEST_PROJECT/calls.log"

  # Fake codex emulating codex 0.142, which dropped `app-server --listen ws://`:
  # the app-server subcommand is rejected, but a plain/resume launch still works.
  export FAKE_CODEX="$TEST_PROJECT/real-codex"
  cat > "$FAKE_CODEX" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "app-server" ]; then
  echo "error: unexpected argument '--listen' found" >&2
  exit 2
fi
printf 'plain-codex' >> "$CALL_LOG"
for arg in "$@"; do printf ' <%s>' "$arg" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
EOF
  chmod +x "$FAKE_CODEX"
}

teardown() {
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

@test "codex-monitor: fails open to plain codex when the app-server won't start (#170)" {
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" bash "$TYPES/codex/codex-monitor.sh" \
    --project "$TEST_PROJECT" --codex-command codex -- --foo
  [ "$status" -eq 0 ]
  # Handed off to a plain codex (no --remote bridge), preserving the args.
  grep -qx 'plain-codex <--foo>' "$CALL_LOG"
  # And it did NOT exec the bridged form.
  ! grep -q -- '--remote' "$CALL_LOG"
  # The fallback is LOUD: the user is told real-time delivery is off.
  [[ "$output" == *"Real-time agmsg delivery is OFF"* ]]
}

@test "codex-monitor: fail-open preserves the resume command" {
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" bash "$TYPES/codex/codex-monitor.sh" \
    --project "$TEST_PROJECT" --codex-command resume --
  [ "$status" -eq 0 ]
  grep -qx 'plain-codex <resume>' "$CALL_LOG"
}
