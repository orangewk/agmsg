#!/usr/bin/env bats
# Driver-agnostic storage-contract tests (docs/spec/driver-interface.md §2,
# ADR 0003). They exercise the storage_* contract through the facade, so the
# SAME tests pin every driver: they run against the built-in sqlite driver here,
# and `AGMSG_STORAGE_DRIVER=<name> bats tests/test_storage_contract.bats` runs the
# identical contract against jsonl / redis once those land.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init
}

teardown() { teardown_test_env; }

# pull the cursor token out of a watch_after stream's trailing cursor record
_cursor_of() { printf '%s\n' "$1" | sed -n 's/.*"type":"cursor","cursor":"\([^"]*\)".*/\1/p'; }

@test "contract: storage_check reports ok" {
  run storage_check
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "contract: send returns an id and list_unread shows the message" {
  local id; id=$(storage_send agsuite alice bob "hi")
  [ -n "$id" ]
  run storage_list_unread agsuite bob
  [ "$status" -eq 0 ]
  [[ "$output" == *'"body":"hi"'* ]]
  [[ "$output" == *"$id"* ]]
}

@test "contract: mark_read_batch is idempotent (double mark is a no-op)" {
  local id; id=$(storage_send agsuite alice bob "x")
  storage_mark_read_batch agsuite bob "$id"
  run storage_list_unread agsuite bob
  [ -z "$output" ]
  # Re-marking the same id changes nothing — still read, no error.
  storage_mark_read_batch agsuite bob "$id"
  run storage_list_unread agsuite bob
  [ -z "$output" ]
}

@test "contract: mark_read is recipient-scoped (one agent's read doesn't hide another's)" {
  local m; m=$(storage_send agsuite alice carol "for carol")
  # bob records a read of carol's message id — scoped to bob, so carol is unaffected.
  storage_mark_read_batch agsuite bob "$m"
  run storage_list_unread agsuite carol
  [[ "$output" == *"for carol"* ]]
}

@test "contract: watch_tip + watch_after deliver only post-tip messages, with a cursor" {
  storage_send agsuite alice bob "before"
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice bob "after"
  run storage_watch_after "$tip" agsuite:bob
  [ "$status" -eq 0 ]
  [[ "$output" == *'"body":"after"'* ]]
  [[ "$output" != *'"body":"before"'* ]]
  [[ "$output" == *'"type":"cursor"'* ]]
}

@test "contract: watch_after advances the cursor even with zero matching messages" {
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice carol "off-subscription"
  run storage_watch_after "$tip" agsuite:bob
  [ "$status" -eq 0 ]
  [[ "$output" != *message_sent* ]]
  local newcur; newcur=$(_cursor_of "$output")
  [ -n "$newcur" ]
  [ "$newcur" != "$tip" ]
}

@test "contract: cursor round-trips — re-watching from it does not re-scan" {
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice bob "m1"
  local out1; out1=$(storage_watch_after "$tip" agsuite:bob)
  [[ "$out1" == *m1* ]]
  local cur1; cur1=$(_cursor_of "$out1")
  run storage_watch_after "$cur1" agsuite:bob
  [[ "$output" != *m1* ]]
}

@test "contract: history returns messages involving the agent" {
  storage_send agsuite alice bob "h1"
  storage_send agsuite bob alice "h2"
  run storage_history agsuite bob
  [[ "$output" == *h1* ]]
  [[ "$output" == *h2* ]]
}

@test "contract: export then import round-trips the event log" {
  local id; id=$(storage_send agsuite alice bob "keep")
  storage_mark_read_batch agsuite bob "$id"
  local f="$TEST_SKILL_DIR/export.jsonl"
  storage_export "$f"
  [ -s "$f" ]
  rm -f "$TEST_SKILL_DIR"/db/messages.db*
  storage_init
  storage_import "$f"
  run storage_history agsuite bob
  [[ "$output" == *keep* ]]
}

@test "contract: record-returning ops emit pure JSONL (no status word on stdout)" {
  storage_send agsuite alice bob "j1"
  run storage_list_unread agsuite bob
  [ "$status" -eq 0 ]
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(sqlite3 :memory: "SELECT json_valid('$(printf '%s' "$line" | sed "s/'/''/g")')")" = "1" ]
  done <<< "$output"
}
