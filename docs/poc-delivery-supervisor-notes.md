# Delivery supervisor PoC notes

Date: 2026-06-28
Branch: `poc/delivery-supervisor`
Scope: disposable PoC, Codex-first direction, no upstream posting.

## What was built

Added a standalone Node PoC supervisor at:

- `scripts/poc/delivery-supervisor.js`

It is intentionally not wired into `delivery.sh` or production hooks.

The supervisor owns:

- project-scoped singleton via port/lock files
- session attach and heartbeat state
- live/stale liveness without trusting OS pid
- mailbox cursor
- mock adapter delivery log
- optional adapter command boundary for separating core failures from adapter failures

Added smoke tests:

- `tests/poc/test-delivery-supervisor.cjs`
- `tests/poc/test-delivery-supervisor-adapter-fail.cjs`

## Observations

### AC1 singleton

Status: yes for PoC core.

Second supervisor startup is rejected when an existing supervisor responds on the project port file.

### AC2 heartbeat liveness

Status: yes for PoC core.

Observed both directions:

- live quiet session remains live after heartbeat
- dead session becomes stale after timeout

### AC3 resume/reattach with cursor

Status: yes for PoC core simulation.

The supervisor process stays alive while a session becomes stale. A held message is delivered after a new session attaches. Cursor prevents duplicate delivery.

This is not yet a real Codex Desktop kill/restart test.

### AC4 real agent idle wake

Status: not yet proven.

The current PoC has a mock adapter and an adapter-command boundary. It has not yet injected into a real Codex Desktop idle thread.

### AC5 single-writer / no duplicate watcher

Status: yes for PoC core.

The singleton port/lock check rejects a second supervisor. The core smoke produced exactly one delivery for the first message and no duplicate delivery while idle.

## Core vs adapter failure split

The adapter-failure smoke starts a supervisor with an adapter command that exits non-zero. Observation:

- `adapter-fail` is recorded in the event log
- cursor does not advance
- delivery can be retried later

This gives a clean split between supervisor core health and adapter delivery failure.

## Current risk

The hardest remaining work is Windows daemon supervision and real Codex idle wake:

- how to keep the supervisor alive outside a session lifecycle
- how to start/stop it safely from hooks or a command
- how to bind a Codex adapter to a real idle Desktop thread without returning to per-session watcher fragility

## Verification run

Passed:

```text
node --check scripts/poc/delivery-supervisor.js
node --check tests/poc/test-delivery-supervisor-adapter-fail.cjs
node tests/poc/test-delivery-supervisor.cjs
node tests/poc/test-delivery-supervisor-adapter-fail.cjs
```
## AC4 adapter phase update

Added a disposable Codex adapter:

- `scripts/poc/codex-idle-wake-adapter.js`

It reads `AGMSG_SUPERVISOR_MESSAGE_JSON`, connects to a Codex app-server WebSocket endpoint, runs:

1. `initialize`
2. `initialized`
3. `thread/loaded/list`
4. `thread/resume`
5. `turn/start`

Added tests:

- `tests/poc/test-codex-idle-wake-adapter.cjs`
- `tests/poc/test-supervisor-codex-adapter.cjs`

Observed:

- Standalone adapter reaches `turn/start` against a fake app-server.
- Supervisor can invoke the adapter command and advance cursor only after adapter success.
- The method sequence is verified in both tests.

### Real Codex idle-wake status

Status: partially blocked.

No live installed agmsg Codex app-server endpoint was available at test time:

- recorded ports `59181` and `51843` were closed
- recorded app-server pids were not alive

Codex CLI exists (`codex-cli 0.138.0`) and supports `codex app-server --listen ws://IP:PORT`, but `codex app-server daemon` lifecycle reports:

```text
Error: codex app-server daemon lifecycle is only supported on Unix platforms
```

This is an important Windows observation: the durable daemon manager that would normally keep the app-server alive is not available on Windows in this Codex CLI version. It reinforces that the hard part is not the `turn/start` adapter protocol, but Windows supervision/lifecycle ownership.

Current AC4 result:

- Adapter protocol to `turn/start`: yes, proven against fake app-server.
- Supervisor -> adapter -> `turn/start`: yes, proven against fake app-server.
- Real Desktop idle-wake: not yet proven because no live Desktop/app-server endpoint was available.
- Windows daemon survival: not yet proven; built-in Codex daemon lifecycle is Unix-only here.

## Verification run update

Passed:

```text
node --check scripts/poc/delivery-supervisor.js
node --check scripts/poc/codex-idle-wake-adapter.js
node tests/poc/test-delivery-supervisor.cjs
node tests/poc/test-delivery-supervisor-adapter-fail.cjs
node tests/poc/test-codex-idle-wake-adapter.cjs
node tests/poc/test-supervisor-codex-adapter.cjs
```
## Supervisor-owned Codex app-server phase

Added a disposable owner script:

- `scripts/poc/codex-app-server-owner.js`

Important boundary finding:

- Node `child_process.spawn("codex", ...)` fails with `EPERM` in Codex Desktop because `codex` resolves to `C:\Users\orang\AppData\Roaming\npm\codex.ps1`.
- Node can spawn `node`, `cmd.exe`, and `powershell.exe` from this session.
- Node can spawn the native Codex executable directly:
  `C:\Users\orang\AppData\Roaming\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe`.

Therefore the PoC owner now prefers native `codex.exe` on Windows.

Observed:

- Owner can start `codex.exe app-server --listen ws://127.0.0.1:<port>` and detect the endpoint.
- Owner can stop the recorded process.
- A PowerShell-wrapper route was unstable and left child `codex.exe` processes; native exe is the correct Windows route for this PoC.

Attempted real app-server adapter probe:

- Start owned native app-server: success.
- Run disposable adapter against owned endpoint with `--thread new`: failed with `read ECONNRESET`.
- App-server log only showed normal startup. No detailed protocol error was emitted.

Interpretation:

- Windows lifecycle ownership is now partially de-risked: the PoC can own a native Codex app-server process.
- The fake app-server adapter path remains green.
- Real owned app-server JSON-RPC/WebSocket behavior is not yet compatible with the disposable adapter. This may be a protocol/version/auth/handshake difference in `codex-cli 0.138.0`, rather than a supervisor-core problem.
- Real Desktop idle-wake remains unproven.

Cleanup:

- Leftover PoC `codex.exe app-server` process was identified by command line and stopped.
## codex-cli --remote smoke attempt

Added a self-contained smoke script:

- `tests/poc/smoke-codex-remote-wake.cjs`

Goal:

1. start supervisor-owned native `codex.exe app-server --listen ws://127.0.0.1:<port>`
2. start `codex --remote <endpoint> --cd <project> --no-alt-screen`
3. use the disposable adapter to inject `turn/start`
4. observe whether an idle real Codex CLI remote session wakes

Result:

- app-server owner started and exposed `ws://127.0.0.1:57482`
- remote CLI process failed immediately with:

```text
Error: stdin is not a terminal
```

- adapter then saw `connect ECONNREFUSED` because the remote/app-server side was no longer available

Classification:

- supervisor owner: started successfully
- adapter: not the primary failure in this run
- real remote session harness: blocked, because `codex --remote` requires a real TTY

Interpretation:

This confirms that the next real wake smoke needs an actual terminal/PTY-backed Codex CLI session, not a background `child_process.spawn` with piped/ignored stdio. On Windows this likely means either a visible terminal launched with `Start-Process` or a PTY-capable harness. The Desktop target is still a later step; this is the CLI-remote stepping stone.
## visible TTY codex --remote wake probe

A visible PowerShell terminal was launched with:

```text
codex.exe --remote <owned-endpoint> --cd C:\dev\MathDesk --no-alt-screen
```

First attempt with the normal adapter path reached a loaded thread but failed at `thread/resume`:

```text
codex-idle-wake-adapter: no rollout found for thread id <id>
```

Classification:

- owned app-server: OK
- visible TTY remote session: OK enough for `thread/loaded/list` to return a loaded thread
- adapter path: failed at `thread/resume`; this appears specific to remote loaded threads without rollout metadata

Added PoC-only adapter option:

```text
--skip-resume
```

Second attempt used `--skip-resume` and called `turn/start` directly on the loaded thread. Result:

```json
{"ok":true,"threadId":"019f0cfd-c2be-7b93-9501-726c508e8228"}
```

Interpretation:

- Real Windows `codex-cli --remote` with a real TTY can attach to a supervisor-owned app-server.
- The disposable adapter can discover the loaded remote thread.
- `turn/start` is accepted by the real app-server when called directly on that loaded thread.
- For this remote-session path, `thread/resume` is not the right prerequisite; it fails because no rollout exists for the loaded remote thread.

Current AC4 result:

- Fake app-server turn/start: yes.
- Supervisor -> adapter -> fake app-server turn/start: yes.
- Supervisor-owned native app-server lifecycle: yes for start/stop and port persistence after owner returns.
- Real codex-cli --remote TTY + direct `turn/start`: yes, request accepted.
- Full user-visible processing/wake observation: partially observed via request acceptance; a longer manual observation can verify the remote TUI rendered/processed the injected turn.
- Desktop path: still not tested; CLI remote is the stepping stone.

Cleanup:

- owned app-server endpoint was closed after stop
- visible PowerShell/Codex probe process tree was stopped

## visible TTY remote wake observation update

Added adapter-side notification observation:

- `--wait-after-start-ms <n>` keeps the disposable adapter connected briefly after `turn/start`
- observed JSON-RPC notifications are returned in the adapter output
- current PoC records `turn/started`, `turn/completed`, `turn/failed`, and `thread/status/changed`

Fake app-server verification now emits `turn/started` and `thread/status/changed`, and the adapter test asserts both are observed.

Real visible TTY probe:

- supervisor-owned app-server endpoint: `ws://127.0.0.1:59436`
- launched visible `codex.exe --remote <endpoint> --cd C:\dev\MathDesk --no-alt-screen`
- adapter args included `--thread loaded --skip-resume --wait-after-start-ms 10000`
- adapter exited 0 with:

```json
{"ok":true,"threadId":"019f0d0c-e2ce-7542-ac4c-eeff35b94137","observed":[{"method":"thread/status/changed","threadId":"019f0d0c-e2ce-7542-ac4c-eeff35b94137","status":"active"}]}
```

Interpretation:

- `turn/start` is not only accepted by the real Windows remote app-server path; the loaded remote thread changes to `active` after injection.
- This is stronger than the previous request-accepted-only result.
- The PoC still has not injected into Codex Desktop directly. The validated stepping stone is: supervisor-owned native app-server + visible TTY `codex --remote` + direct `turn/start` on the loaded thread.

Cleanup:

- app-server owner stopped pid `19792`
- visible terminal process tree was requested to stop; a follow-up process scan found no leftover probe app-server/remote process

## supervisor-to-visible-remote smoke update

Added a Windows-only visible smoke script:

- `tests/poc/smoke-supervisor-codex-remote-visible.ps1`

The script validates the full stepping-stone path:

1. start supervisor-owned native Codex app-server
2. launch a visible TTY-backed `codex.exe --remote <endpoint> --cd <project> --no-alt-screen`
3. start `delivery-supervisor.js` with the real Codex adapter command
4. attach a live `mathdesk-desktop/Eiji` session
5. send one supervisor message from `Anna` to `Eiji`
6. verify supervisor cursor advances and adapter stdout reports `thread/status/changed` with `status: active`

Supervisor now records adapter success output as an `adapter-ok` event. This gives the smoke script a durable place to verify the adapter's observed Codex events without coupling the supervisor core to Codex internals.

Clean smoke result:

```json
{
  "ok": true,
  "endpoint": "ws://127.0.0.1:57889",
  "cursor": 1,
  "threadId": "019f0d24-8be8-7183-9df6-8f3216e8484d",
  "observed": [
    {
      "method": "thread/status/changed",
      "threadId": "019f0d24-8be8-7183-9df6-8f3216e8484d",
      "status": "active"
    }
  ]
}
```

Interpretation:

- The PoC now proves supervisor -> adapter -> visible Codex remote -> active thread as one integrated path.
- This is still not Codex Desktop direct injection. It is the strongest CLI-remote stepping stone so far and should be the base for deciding whether/how to bridge into Desktop.

## feasibility verdict and liveness design handoff

Feasibility verdict for this PoC:

- The integrated stepping-stone path is proven on Windows:
  `delivery-supervisor -> Codex adapter -> visible TTY codex --remote -> thread/status/changed active`.
- This is enough to stop expanding the heartbeat-based PoC core.
- The PoC should remain a feasibility artifact, not become production monitor design by accretion.

Liveness handoff:

- Decision owner for the heartbeat prohibition: orange.
- Design owner for the replacement liveness model: Anna.
- Implementation owner for the later build slice: Eiji/Codex, after the feasibility verdict is accepted.

Build-stage direction from Anna's design note (`C:\dev\rt-monitor-rnd\design-supervisor-liveness.md`):

- Replace timestamp heartbeat with held-connection liveness.
- Do not ask the LLM to emit heartbeat/ping messages.
- Do not add per-session timer processes just to keep liveness fresh.
- Treat the already-required delivery connection as the liveness primitive:
  - open connection/register frame = live seat binding
  - transport drop = dead
  - reconnect with cursor = resume
- For Codex, register/bind the target seat to the remote/app-server/thread identity rather than guessing a delivery target.

Implication for PR #3:

- No further investment should go into `lastHeartbeat`, `heartbeat`, or `markStale` beyond their current disposable PoC role.
- Any next implementation PR should start from held-connection liveness, using this PR only for the adapter and Windows remote feasibility evidence.

## next-target-B closure probes

Anna requested two remaining checks before declaring target 2 closed.

### Check 1: Codex Desktop GUI direct route

Status: FAIL / blocked by missing external Desktop app-server endpoint.

Observed on the real Codex Desktop app (Windows):

- Codex Desktop GUI process is running.
- It owns a child process:
  `resources\codex.exe app-server --analytics-default-enabled`.
- That process does not expose a localhost WebSocket listener for external `turn/start` injection.
- `Get-NetTCPConnection` for the Desktop app-server pid showed outbound HTTPS connections only, not a local `ws://127.0.0.1:<port>` listener.
- `codex app-server proxy` attempts to connect to `C:\Users\orang\.codex\app-server-control\app-server-control.sock` and fails on Windows.
- `codex remote-control start --json` and `codex app-server daemon version` both fail with:
  `codex app-server daemon lifecycle is only supported on Unix platforms`.
- Named pipe `\\.\pipe\codex-ipc` exists, but it is not a documented app-server JSON-RPC/WebSocket endpoint and was not used as a workaround.

Conclusion:

- The current PoC cannot honestly claim `supervisor -> adapter -> existing Codex Desktop GUI app-server -> turn/start`.
- To test or build Desktop GUI direct injection, Codex Desktop needs one of:
  - a supported WebSocket listener / remote-control endpoint on Windows,
  - a documented Desktop IPC bridge for app-server JSON-RPC,
  - or an explicit app-internal tool route accepted as a different integration surface.
- Fake Desktop substitution is intentionally rejected.

### Check 2: one step past active/render evidence

Status: PASS for the CLI-remote stepping-stone path; strict `turn/completed` notification is not emitted to the adapter, but completion is confirmed through active->idle plus Codex Desktop thread record.

Prompt override was added to the disposable adapter:

- `--prompt-text <text>` bypasses the default `[$agmsg]` prompt wrapper for probe turns.
- Reason: the default wrapper triggers the agmsg skill in remote Codex and can block on identity/sqlite setup, which is not the render/completion question.

Smoke script was extended:

- `-PromptText <text>`
- `-RequireIdleAfterActive`
- `-RequireCompleted` remains available as a strict notification check, but it is not satisfied in this environment.

Clean completion probe:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\poc\smoke-supervisor-codex-remote-visible.ps1 `
  -Project C:\dev\MathDesk `
  -WaitAfterStartMs 30000 `
  -PromptText 'Reply exactly POC_RENDER_OK. Do not run tools.' `
  -RequireIdleAfterActive
```

Adapter evidence:

```json
{
  "ok": true,
  "threadId": "019f0d61-af7a-7c52-bce9-f584a2da32d7",
  "observed": [
    { "method": "thread/status/changed", "status": "active" },
    { "method": "thread/status/changed", "status": "idle" }
  ]
}
```

Codex Desktop thread record evidence:

- thread id: `019f0d61-af7a-7c52-bce9-f584a2da32d7`
- turn status: `completed`
- final answer: `POC_RENDER_OK`

Conclusion:

- The CLI-remote path renders/processes a turn and reaches completed state, even though the adapter observes status notifications rather than a `turn/completed` notification.
- This closes the render/completion concern for the remote stepping stone, not for existing Desktop GUI direct injection.

## app-internal conditional wake dogfood

Goal:

- Do not wake the target Codex Desktop thread on empty polling runs.
- Wake the target thread only when agmsg reports unread mail for that target identity.
- Keep unread message content in agmsg until the target thread reads it with the official inbox script.

Setup used in MathDesk dogfood:

- collector runner thread: `019f0e3b-c3c1-7ab0-8781-166cdb12c7d4`
- target thread: `JunoMaCoder中学受験` / `019f0794-1b19-7f80-81be-b823e3035b5e`
- target identity: `JunoMaCoder`
- team: `mathdesk-desktop`
- unread oracle: `scripts/drivers/types/codex/watch-once.sh`
- target wake route: Codex app-internal `send_message_to_thread`
- state file: `C:\tmp\agmsg-junoma-conditional-waker-state.json`

Observed flow:

1. With no unread mail, `watch-once.sh` returned `status=timeout`; the target thread received no turn.
2. Eiji sent one agmsg message to JunoMaCoder.
3. The collector heartbeat observed `status=pending count=1 max_id=171` via `watch-once.sh`.
4. The collector wrote `last_notified_max_id=171` and sent one wake prompt to the target thread.
5. JunoMaCoder woke, ran the official inbox path, read the message, and replied to Eiji.
6. Later collector runs saw no unread mail and did not send duplicate wake prompts.

Result:

- PASS for "unread-only target wake" in Codex Desktop, using an app-internal thread tool route.
- PASS for preserving unread ownership: the watcher did not read message content or mark it read.
- PASS for duplicate suppression in this smoke run.

Boundary:

- This is not direct Desktop GUI app-server injection.
- This depends on a Codex app-internal `send_message_to_thread` route that is available to Codex agents in this environment, not a standalone shell-only process.
- Empty polling runs still consume the collector thread, but they do not consume or wake the target work thread.

Interpretation:

This gives a practical companion design for Codex Desktop today: keep polling and no-op noise in a dedicated collector session, and wake the actual work session only when the official agmsg unread oracle reports pending mail. It should be described as a companion/waker path, not as monitor bridge completion.
