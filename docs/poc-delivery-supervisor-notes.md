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
