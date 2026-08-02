#!/usr/bin/env bats

# Unit tests for codex-bridge-launcher.sh thread resolution (#350).
# The launcher must bind the bridge to the role's RECORDED codex thread instead
# of the app-server's ambiguous "loaded" thread (which a co-resident codex thread
# in the same cwd could otherwise capture). A mock bridge (AGMSG_CODEX_BRIDGE_CMD)
# records the --thread the launcher passes.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export PROJ="$TEST_SKILL_DIR/proj"; mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null

  export CAPTURE="$TEST_SKILL_DIR/thread-capture.txt"
  export MOCK="$TEST_SKILL_DIR/mock-bridge.sh"
  cat > "$MOCK" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
[ -z "\${MOCK_BRIDGE_SLEEP:-}" ] || sleep "\$MOCK_BRIDGE_SLEEP"
exit 0
EOF
  chmod +x "$MOCK"
  export AGMSG_CODEX_BRIDGE_CMD="$MOCK"
  export LAUNCHER="$SCRIPTS/drivers/types/codex/codex-bridge-launcher.sh"

  # Observe launcher ownership through the same storage seam used in
  # production. This is portable to Git Bash, whose minimal ps lacks -Ao.
  source "$SCRIPTS/lib/hash.sh"
  source "$SCRIPTS/lib/instance-id.sh"
  source "$SCRIPTS/lib/storage.sh"
  local project_hash pair_hash
  project_hash="$(printf '%s' "$PROJ" | agmsg_sha1)"
  pair_hash="$(printf '%s' $'team\talice' | agmsg_sha1)"
  export DISPATCHER_LOCK_RESOURCE="codex-dispatcher:$project_hash"
  export CHILD_LOCK_RESOURCE="codex-child:$project_hash:$pair_hash"
}

teardown() { teardown_test_env; }

# Write a role-session record (team, agent) -> thread for a project.
put_record() {
  SKILL_DIR="$TEST_SKILL_DIR" bash -c \
    'source "$1/lib/role-session.sh"; agmsg_role_session_record "$2" "$3" "$4" "$5" "$6"' \
    _ "$SCRIPTS" "$@"
}

write_request() {
  local thread="$1" hash
  hash=$(SKILL_DIR="$TEST_SKILL_DIR" bash -c \
    'source "$1/lib/hash.sh"; printf "%s" "$2" | agmsg_sha1' _ "$SCRIPTS" "$PROJ")
  printf 'codex\t%s\tws://127.0.0.1:1\n' "$thread" > "$RUN_DIR/codex-bridge-request.$hash"
}

wait_for_capture_lines() {
  local want="$1" i lines=0
  for i in {1..150}; do
    if [ -f "$CAPTURE" ]; then
      lines="$(wc -l < "$CAPTURE" | tr -d ' ')"
    fi
    [ "$lines" -ge "$want" ] && break
    sleep 0.1
  done
  printf '%s\n' "$lines"
}

wait_for_live_lock_owner() {
  local resource="$1" i owner=""
  for i in {1..150}; do
    owner="$(agmsg_runtime_lock_owner "$resource" 2>/dev/null || true)"
    if [ -n "$owner" ] && _agmsg_pid_alive_local "$owner"; then
      printf '%s\n' "$owner"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_lock_release() {
  local resource="$1" i owner=""
  for i in {1..150}; do
    owner="$(agmsg_runtime_lock_owner "$resource" 2>/dev/null || true)"
    [ -z "$owner" ] && return 0
    sleep 0.1
  done
  return 1
}

# Drive the launcher against a short-lived parent, blocking until it exits. fd 3
# is closed on the backgrounded parent and the launcher so a stray descriptor
# can't keep bats from exiting on macOS (#bats-fd3).
run_launcher() {
  sleep 6 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  # The launcher starts the mock through nohup. Its bound-thread metadata is
  # written synchronously, but the mock's capture can land just after the
  # parent exits, especially now that a per-role child launcher is involved.
  local i
  for i in {1..30}; do
    [ -f "$CAPTURE" ] && break
    sleep 0.1
  done
}

@test "launcher: binds the recorded thread when the record's project matches (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ -f "$CAPTURE" ]
  grep -q -- "--thread rec-thread-1" "$CAPTURE"
  ! grep -q -- "--thread loaded" "$CAPTURE"
}

@test "launcher: passes the active storage override as a workspace root" {
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/custom-store"
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher

  grep -q -- "--workspace-root $AGMSG_STORAGE_PATH" "$CAPTURE"
  ! grep -q -- "--workspace-root $TEST_SKILL_DIR/db" "$CAPTURE"
}

@test "launcher: leaves a role without a recorded live thread unsubscribed (#150)" {
  run_launcher
  [ ! -f "$CAPTURE" ]
}

@test "launcher: leaves a role with a foreign-project record unsubscribed (#150)" {
  put_record team alice other-thread "/some/other/project" codex
  run_launcher
  [ ! -f "$CAPTURE" ]
}

@test "launcher: writes the bound-thread file so a later launcher can rebind (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ "$(cat "$RUN_DIR/codex-bridge.team.alice.thread" 2>/dev/null)" = "rec-thread-1" ]
}

@test "launcher: replaces a stale role pidfile with the spawned bridge pid" {
  put_record team alice rec-thread-1 "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=3
  printf '%s\n' 99999999 > "$RUN_DIR/codex-bridge.team.alice.pid"
  sleep 30 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!

  local i recorded="" recorded_alive=1
  for i in {1..150}; do
    recorded="$(cat "$RUN_DIR/codex-bridge.team.alice.pid" 2>/dev/null || true)"
    if [ -n "$recorded" ] && [ "$recorded" != 99999999 ] && _agmsg_pid_alive_local "$recorded"; then
      recorded_alive=0
      break
    fi
    sleep 0.1
  done

  kill "$dispatcher" "$parent" 2>/dev/null || true
  wait "$dispatcher" 2>/dev/null || true
  wait "$parent" 2>/dev/null || true

  [ -n "$recorded" ]
  [ "$recorded" != 99999999 ]
  [ "$recorded_alive" -eq 0 ]
}

@test "launcher: starts one bridge per recorded role and thread (#150 phase 2)" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  put_record team bob thread-bob "$PROJ" codex
  run_launcher

  local i lines=0
  for i in {1..30}; do
    if [ -f "$CAPTURE" ]; then
      lines=$(wc -l < "$CAPTURE" | tr -d ' ')
    fi
    [ "$lines" -ge 2 ] && break
    sleep 0.1
  done
  [ "$lines" -ge 2 ]
  grep -q -- $'--pair team\talice --thread thread-alice' "$CAPTURE"
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"
}

@test "launcher: only one dispatcher runs per project" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=8
  sleep 30 3>&- & local parent_a=$!
  sleep 30 3>&- & local parent_b=$!

  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local launcher_a=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local launcher_b=$!

  local dispatcher_owner="" child_owner="" lines=0
  dispatcher_owner="$(wait_for_live_lock_owner "$DISPATCHER_LOCK_RESOURCE" || true)"
  child_owner="$(wait_for_live_lock_owner "$CHILD_LOCK_RESOURCE" || true)"
  lines="$(wait_for_capture_lines 1)"
  sleep 1
  [ -f "$CAPTURE" ] && lines="$(wc -l < "$CAPTURE" | tr -d ' ')"

  kill "$launcher_a" "$launcher_b" "$parent_a" "$parent_b" 2>/dev/null || true
  wait "$launcher_a" 2>/dev/null || true
  wait "$launcher_b" 2>/dev/null || true
  wait "$parent_a" 2>/dev/null || true
  wait "$parent_b" 2>/dev/null || true

  [ -n "$dispatcher_owner" ]
  [ -n "$child_owner" ]
  [ "$lines" -eq 1 ]
}

@test "launcher: stale dispatcher reclamation remains singleton under contention" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=8
  local hash lock_db
  hash=$(printf '%s' "$PROJ" | bash -c 'source "$1"; agmsg_sha1' _ "$SCRIPTS/lib/hash.sh")
  lock_db="$TEST_SKILL_DIR/db/messages.db"
  sqlite3 "$lock_db" "CREATE TABLE locks(resource TEXT PRIMARY KEY, owner_pid INTEGER NOT NULL, acquired_at TEXT NOT NULL); INSERT INTO locks VALUES('codex-dispatcher:$hash', 99999999, datetime('now'));"
  # A crash from the former two-directory implementation can leave this behind.
  # The transactional lock protocol must not depend on that legacy reaper.
  mkdir "$RUN_DIR/codex-bridge-dispatcher.$hash.reap"
  export AGMSG_TEST_DISPATCHER_STALE_BARRIER="$TEST_SKILL_DIR/stale-observed"
  sleep 30 3>&- & local parent_a=$!
  sleep 30 3>&- & local parent_b=$!

  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local launcher_a=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local launcher_b=$!

  local dispatcher_owner="" child_owner="" lines=0
  dispatcher_owner="$(wait_for_live_lock_owner "$DISPATCHER_LOCK_RESOURCE" || true)"
  child_owner="$(wait_for_live_lock_owner "$CHILD_LOCK_RESOURCE" || true)"
  lines="$(wait_for_capture_lines 1)"
  sleep 1
  [ -f "$CAPTURE" ] && lines="$(wc -l < "$CAPTURE" | tr -d ' ')"

  kill "$launcher_a" "$launcher_b" "$parent_a" "$parent_b" 2>/dev/null || true
  wait "$launcher_a" 2>/dev/null || true
  wait "$launcher_b" 2>/dev/null || true
  wait "$parent_a" 2>/dev/null || true
  wait "$parent_b" 2>/dev/null || true

  [ -n "$dispatcher_owner" ]
  [ -n "$child_owner" ]
  [ "$lines" -eq 1 ]
}

@test "launcher: project request thread never overrides per-role recorded threads (#150 phase 2)" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  put_record team bob thread-bob "$PROJ" codex
  write_request thread-bob
  run_launcher

  grep -q -- $'--pair team\talice --thread thread-alice' "$CAPTURE"
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"
  ! grep -q -- $'--pair team\talice --thread thread-bob' "$CAPTURE"
}

@test "launcher: role record update keeps child scoped to the same pair" {
  put_record team alice thread-before "$PROJ" codex
  sleep 30 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" $'team\talice' >/dev/null 2>&1 3>&- &
  local launcher_pid=$!
  local i
  for i in {1..150}; do
    grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE"
  put_record team alice thread-after "$PROJ" codex
  for i in {1..150}; do
    grep -q -- $'--pair team\talice --thread thread-after' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done

  kill "$launcher_pid" "$p" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  wait "$p" 2>/dev/null || true

  grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE"
  grep -q -- $'--pair team\talice --thread thread-after' "$CAPTURE"
  ! grep -q -- '--pair team bob' "$CAPTURE"
}

@test "launcher: a replacement dispatcher does not double the role children (#485)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=12
  sleep 45 3>&- & local parent_a=$!
  sleep 45 3>&- & local parent_b=$!

  # Dispatcher A spawns the role child, which is nohup'd and outlives A.
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local dispatcher_a=$!
  local child_a="" child_after_kill="" child_after_replacement=""
  child_a="$(wait_for_live_lock_owner "$CHILD_LOCK_RESOURCE" || true)"

  # SIGKILL is what a pane teardown effectively does to a dispatcher that never
  # trapped the signal: the EXIT trap does not run, so the lock row is left
  # behind owned by a dead pid, exactly the state a replacement dispatcher hits.
  kill -9 "$dispatcher_a" 2>/dev/null || true
  wait "$dispatcher_a" 2>/dev/null || true
  child_after_kill="$(wait_for_live_lock_owner "$CHILD_LOCK_RESOURCE" || true)"

  # Dispatcher B reclaims the stale lock and, with an empty known_pairs, spawns
  # a second child for the SAME pair. Without the per-role lock that child would
  # live on and poll forever alongside the first.
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local dispatcher_b=$!
  # The duplicate is spawned and then loses the lock race. The original live
  # owner must remain unchanged after the replacement dispatcher settles.
  child_after_replacement="$(wait_for_live_lock_owner "$CHILD_LOCK_RESOURCE" || true)"
  sleep 1
  local settled_owner="$(agmsg_runtime_lock_owner "$CHILD_LOCK_RESOURCE" 2>/dev/null || true)"

  kill "$dispatcher_b" 2>/dev/null || true
  wait "$dispatcher_b" 2>/dev/null || true
  kill "$parent_a" "$parent_b" 2>/dev/null || true
  wait "$parent_a" 2>/dev/null || true
  wait "$parent_b" 2>/dev/null || true
  # The role child polls its parent. Wait for that observed shutdown before
  # teardown removes the SQLite fixture; otherwise Windows can catch its WAL
  # connection between parent exit and the child's next poll.
  wait_for_pid_exit "$child_a" || true

  [ -n "$child_a" ]
  [ "$child_after_kill" = "$child_a" ]
  [ "$child_after_replacement" = "$child_a" ]
  [ "$settled_owner" = "$child_a" ]
}

@test "launcher: a re-registered role gets a fresh child after deregistration (#485)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=12
  sleep 60 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!
  local child_before="" child_after="" released=1
  child_before="$(wait_for_live_lock_owner "$CHILD_LOCK_RESOURCE" || true)"

  # Deregistering the role retires its child through the existing re-exec path.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null 2>&1 || true
  if wait_for_lock_release "$CHILD_LOCK_RESOURCE"; then released=0; fi

  # The dispatcher must have forgotten the pair. Otherwise known_pairs still
  # lists it, the re-spawn is suppressed, and the role silently never gets a
  # bridge again for the rest of the app-server's life.
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  child_after="$(wait_for_live_lock_owner "$CHILD_LOCK_RESOURCE" || true)"

  kill "$dispatcher" 2>/dev/null || true
  wait "$dispatcher" 2>/dev/null || true
  kill "$parent" 2>/dev/null || true
  wait "$parent" 2>/dev/null || true

  [ -n "$child_before" ]
  [ "$released" -eq 0 ]
  [ -n "$child_after" ]
  [ "$child_after" != "$child_before" ]
}

@test "launcher: the identity cache still sees a role added mid-loop (#466)" {
  # The poll no longer re-runs identities.sh every tick; it serves a cache
  # guarded on the team configs' mtimes. This is the test that fails if that
  # guard never invalidates: a role joined while the dispatcher is already
  # looping has to be picked up anyway.
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=20
  sleep 25 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!
  local i
  for i in {1..80}; do
    grep -q -- $'--pair team\talice' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- $'--pair team\talice' "$CAPTURE"

  # Let the loop settle into its backed-off steady state before changing
  # anything, so this exercises a cache hit being invalidated rather than a
  # loop that happened to still be resolving every tick.
  sleep 3
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team bob thread-bob "$PROJ" codex
  for i in {1..100}; do
    grep -q -- $'--pair team\tbob' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"

  kill "$dispatcher" 2>/dev/null || true
  wait "$dispatcher" 2>/dev/null || true
  kill "$parent" 2>/dev/null || true
  wait "$parent" 2>/dev/null || true
}

# --- which pid space (#567) ---

@test "launcher: starts the bridge when tasklist cannot see the parent (#567)" {
  skip_on_windows "stubs tasklist to model Git Bash; the real one is authoritative there"
  # Every pid the launcher waits on -- PARENT_PID, LIFETIME_PID, the dispatcher
  # lock owner -- is minted by $! or $$ in one of these shells, so under Git Bash
  # it is numbered in the MSYS space and `tasklist` has no record of it. A probe
  # that asks tasklist calls the live parent dead: the startup loop is never
  # entered, the supervision loop never runs, and no bridge is ever launched.
  # Measured on our own Windows runner -- $$, $! and a pid read back from a
  # pidfile all report tasklist_hits=0 while kill -0 answers yes.
  local stubdir="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stubdir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stubdir/tasklist"
  chmod +x "$stubdir/tasklist"

  put_record team alice thread-msys "$PROJ" codex

  sleep 6 3>&- & local p=$!
  MSYSTEM=MINGW64 PATH="$stubdir:$PATH" \
    bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  local i
  for i in {1..30}; do [ -f "$CAPTURE" ] && break; sleep 0.1; done

  # A bridge was launched at all -- this is what the whole class costs on Windows.
  [ -f "$CAPTURE" ] || { echo "no bridge was started under a blind tasklist"; false; }
  grep -q -- '--thread thread-msys' "$CAPTURE"
}

@test "launcher: windows-native starts the bridge (#567)" {
  skip_unless_windows "the point is the real tasklist and the real MSYS pid space"
  # The counterpart to codex-monitor's windows-native test, and the half #582
  # does NOT fix: reaching the bridged handoff is not the same as delivering a
  # message. PARENT_PID is codex-monitor.sh's own $$, so on Git Bash the loops
  # at :291 and :381 are asking tasklist about an MSYS pid -- false on the first
  # evaluation, which means neither loop turns over and no bridge is ever
  # started. Real tasklist, no stub.
  put_record team alice thread-win "$PROJ" codex

  sleep 6 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  local i
  for i in {1..30}; do [ -f "$CAPTURE" ] && break; sleep 0.1; done

  [ -f "$CAPTURE" ] || { echo "no bridge was started on native Windows"; false; }
  grep -q -- '--thread thread-win' "$CAPTURE"
}
