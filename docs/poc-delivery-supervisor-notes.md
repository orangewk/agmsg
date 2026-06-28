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
