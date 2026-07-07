#!/usr/bin/env node
"use strict";
//
// test-idle-ttl.cjs — direct-execution regression test for lib/idle-ttl.sh,
// gc.sh's idle-ttl pidfile reaper, and the codex-bridge native-pid liveness
// fix (orangewk/agmsg#8 WP2).
//
// Run via plain `node`, following the same pattern as tests/test-manifest-gc.cjs
// (bats hangs on this Windows dev box; see that file's header for the citation).
//
// Covers:
//   1. idle_ttl_established_count: reports the ACTUAL OS-level count of
//      ESTABLISHED TCP peers on a loopback port — 1 while a real client socket
//      is connected, 0 the instant it disconnects. This is the held-connection
//      liveness primitive itself, so this is the single most important
//      assertion in this file: if this ever silently returns "0 while
//      connected" the whole idle-TTL design's fail-safety collapses.
//   2. idle_ttl_run_loop: exits immediately (no kill, no manifest dispose) when
//      the server pid is already dead — "nothing to reap" is not "reap it".
//   3. idle_ttl_run_loop: exits immediately without touching the server when a
//      newer codex-monitor.sh invocation has replaced the recorded server pid
//      in the pidfile (supersession guard).
//   4. idle_ttl_run_loop: kills the server and records a manifest dispose line
//      once established-connection count has been 0 for >= ttl_seconds, using
//      a REAL TCP listener standing in for the app-server (no mocked pid
//      numbers — the port-liveness check is exercised for real).
//   5. idle_ttl_run_loop: does NOT kill the server while a real TCP client
//      keeps a connection open through the same TTL window.
//   6. gc.sh's agmsg_gc_codex_idle_ttl_pidfiles: reaps a dead reaper pidfile,
//      leaves a live+cmdline-confirmed one alone, and does not let the
//      existing app-server pidfile reaper (agmsg_gc_codex_app_server_pidfiles)
//      accidentally sweep up the idle-ttl pidfile (glob-overlap regression
//      guard — see gc.sh's own NOTE on this).
//   7. codex-bridge-launcher.sh / _session-start.sh native-pid liveness fix:
//      a live, nohup-launched native-pid bridge is now correctly detected as
//      alive (WP1 found both call sites used `kill -0` on a native pid, which
//      always reports dead; WP2 fixes both to use _agmsg_pid_alive).

const assert = require("assert");
const { execFileSync, spawn } = require("child_process");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const bash = findBash();
// Every child-process env below is BASH_ENV, not process.env directly (see
// bashEnv() just below `findBash`): a bare `node tests/test-idle-ttl.cjs` run
// from a shell whose PATH never picked up Git for Windows' `usr/bin` (the
// MSYS2 coreutils dir — rm/dirname/uname/etc) — e.g. a plain PowerShell/cmd.exe
// prompt, as opposed to a Git Bash prompt where that shell's own startup
// already prepended it — spawns a bash.exe that IS the right MSYS runtime
// (found by absolute path below) but then can't find `rm`, `dirname`, or
// `uname` on PATH once it's running, because PATH is inherited from the
// parent process, not derived from the bash.exe binary's own location.
// Confirmed by direct repro: identical script, green under a Git-Bash-launched
// shell, failing with "rm: command not found" / "dirname: command not found"
// under PowerShell. Every script this file sources (compat.sh's `uname`,
// gc.sh's `rm`, codex-monitor.sh's `dirname`) needs those binaries, so this
// must be fixed once, for every spawn site in this file, not per call site.
function findBash() {
  const candidates = [
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "bash",
  ];
  for (const c of candidates) {
    try {
      execFileSync(c, ["--version"], { stdio: "ignore" });
      return c;
    } catch (_) {
      // try next
    }
  }
  throw new Error("no usable bash found for test harness");
}

// Env to pass to every spawned bash.exe / bash -c child process in this file:
// process.env with (a) the MSYS coreutils dir prepended to PATH and (b)
// MSYSTEM set, when missing, to match the MSYS runtime `bash` above actually
// resolved to.
//
// (a) When `bash` resolved to an absolute path (the normal case — see
// findBash()'s candidate list), that path's own directory (Git for Windows'
// usr/bin) is exactly the directory bash.exe's own MSYS runtime expects on
// PATH; prepending it makes `rm`, `dirname`, `uname`, etc. resolve regardless
// of what shell launched this test.
//
// (b) MSYSTEM is how idle-ttl.sh's idle_ttl_established_count and
// instance-id.sh's _agmsg_pid_alive detect "am I really running under the
// MINGW/MSYS bash whose Get-NetTCPConnection / tasklist codepath applies" —
// see both functions' own `case "${MSYSTEM:-}" in MINGW*|MSYS*|CLANGARM*)`
// guards. bash.exe itself always sets MSYSTEM once it starts (confirmed:
// `bash.exe -c 'echo $MSYSTEM'` prints MINGW64 even under `env -i`), but
// child_process.execFileSync/spawn pass the PARENT's env, not a freshly
// bash-initialized one — env is applied before bash.exe's own startup can set
// it, so an explicit parent-side MSYSTEM (e.g. a Git Bash terminal) IS seen by
// the child, but no MSYSTEM in the parent (e.g. a plain PowerShell/cmd.exe
// prompt spawning this test with `node tests/test-idle-ttl.cjs`) means the
// child never gets one either — confirmed by direct repro: identical script,
// MSYSTEM=MINGW64 printed under a Git-Bash-launched shell, MSYSTEM=[] under
// PowerShell, which cascades into idle_ttl_established_count and
// _agmsg_pid_alive both silently taking their non-Windows fallback path (fail-
// closed "unknown" / plain `kill -0`) even though the bash.exe actually
// running IS the MINGW64 build. Only ever fills in a MISSING MSYSTEM — never
// overrides one the parent shell already set — and only on win32 (a
// Linux/macOS CI runner's `bash` fallback should never see a Windows-only
// value forced onto it).
function bashEnv() {
  const env = { ...process.env };
  if (process.platform === "win32" && !env.MSYSTEM) {
    env.MSYSTEM = "MINGW64";
  }
  if (!path.isAbsolute(bash)) return env;
  const bashDir = path.dirname(bash);
  const currentPath = env.PATH || env.Path || "";
  if (currentPath.split(path.delimiter).includes(bashDir)) return env;
  env.PATH = `${bashDir}${path.delimiter}${currentPath}`;
  return env;
}

function mkSkillDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-idle-ttl-test-"));
  fs.mkdirSync(path.join(dir, "scripts", "lib"), { recursive: true });
  fs.mkdirSync(path.join(dir, "run"), { recursive: true });
  for (const f of ["manifest.sh", "gc.sh", "compat.sh", "instance-id.sh", "idle-ttl.sh"]) {
    fs.copyFileSync(
      path.join(repo, "scripts", "lib", f),
      path.join(dir, "scripts", "lib", f),
    );
  }
  return dir;
}

function runBash(skillDir, script, { timeoutMs } = {}) {
  const wrapped = `
set -euo pipefail
SKILL_DIR=${bashQuote(skillDir)}
source "$SKILL_DIR/scripts/lib/compat.sh"
source "$SKILL_DIR/scripts/lib/instance-id.sh"
source "$SKILL_DIR/scripts/lib/manifest.sh"
source "$SKILL_DIR/scripts/lib/gc.sh"
source "$SKILL_DIR/scripts/lib/idle-ttl.sh"
${script}
`;
  return execFileSync(bash, ["-c", wrapped], { encoding: "utf8", timeout: timeoutMs || 20000, env: bashEnv() });
}

function bashQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function manifestLines(skillDir) {
  const p = path.join(skillDir, "run", "manifest.jsonl");
  if (!fs.existsSync(p)) return [];
  return fs
    .readFileSync(p, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function listenOnce() {
  return new Promise((resolve) => {
    const srv = net.createServer((socket) => {
      srv._sockets = srv._sockets || [];
      srv._sockets.push(socket);
    });
    srv.listen(0, "127.0.0.1", () => resolve(srv));
  });
}

// Spawn a long-lived MSYS-space dummy "server" process and return its bash
// $! pid — i.e. reproduce codex-monitor.sh's OWN launch shape ("$REAL_CODEX"
// app-server ... & ; server_bg="$!") rather than a Node child_process.spawn()
// pid.
//
// THIS DISTINCTION IS LOAD-BEARING, confirmed by direct repro while building
// this test file: a Node-spawned child's OWN reported `child.pid` (even
// spawned directly, no nohup involved) is NOT visible to `kill -0` from an
// MSYS bash — `kill -0 <that pid>` reports "No such process" while
// `tasklist /FI "PID eq <that pid>"` finds it. idle_ttl_run_loop's server_pid
// contract is explicitly msys-space (see idle-ttl.sh's own doc comment on
// <server_pid>, mirroring codex-monitor.sh's server_bg="$!" of a plain `&`
// background) — using a Node-spawned pid here would make every "is the
// server still alive" kill -0 check in the function under test report "dead"
// immediately, which is exactly the msys/native pid-space confusion this
// whole WP2 effort is about (see manifest.sh's PID SPACE DECISION comment).
// A bash `sleep 9999 & echo $!` reproduces the REAL msys pid space instead.
function spawnMsysDummyServer(skillDir) {
  // Redirect the backgrounded job's stdio away from the parent's pipes
  // (</dev/null >/dev/null 2>&1): without this, execFileSync's own stdout
  // pipe stays open (inherited by the backgrounded process) and the
  // "$(...)"-equivalent read from this parent bash never sees EOF — the
  // whole execFileSync call hangs until timeout. Confirmed by direct repro
  // while building this test file (a `while` loop background job hung this
  // exact way; a bare `sleep` happened not to, but both get the same
  // treatment here to not depend on which external command's own stdio
  // habits happen to save the day).
  const pidStr = execFileSync(
    bash,
    ["-c", "sleep 9999 </dev/null >/dev/null 2>&1 & disown; echo $!"],
    { encoding: "utf8", cwd: skillDir, env: bashEnv() },
  ).trim();
  return Number(pidStr);
}

function msysPidAlive(pid) {
  try {
    execFileSync(bash, ["-c", `kill -0 ${pid} 2>/dev/null`], { encoding: "utf8", env: bashEnv() });
    return true;
  } catch (_) {
    return false;
  }
}

function killMsysPid(pid) {
  try {
    execFileSync(bash, ["-c", `kill ${pid} 2>/dev/null || true`], { encoding: "utf8", env: bashEnv() });
  } catch (_) {
    // best-effort
  }
}

// Tests run strictly SEQUENTIALLY (registered here, executed in order at the
// bottom of this file) — not Promise.all'd. Each test binds real OS resources
// (loopback TCP ports chosen by the OS, spawned child process pids); running
// them concurrently risks two tests' "kill the idle server" logic racing
// against each other's still-live fixtures on a shared, non-isolated resource
// space (the OS process/port tables), which is exactly the kind of flakiness
// this file's own subject matter (pid reuse, port reuse) would make painful
// to debug. Sequential execution costs a few extra seconds of wall clock and
// buys determinism.
let failures = 0;
const registry = [];
function test(name, fn) {
  registry.push({ name, fn });
}

async function runAll() {
  for (const { name, fn } of registry) {
    try {
      await fn();
      console.log(`ok - ${name}`);
    } catch (error) {
      failures++;
      console.log(`not ok - ${name}`);
      console.log(String(error && error.stack ? error.stack : error).split("\n").map((l) => `  ${l}`).join("\n"));
    }
  }
}

// --- 1. idle_ttl_established_count reflects REAL held-connection state -----
(() => {
  test("idle_ttl_established_count is 0 before connect, >=1 while connected, 0 after disconnect", async () => {
    const dir = mkSkillDir();
    try {
      const srv = await listenOnce();
      const port = srv.address().port;

      const before = runBash(dir, `idle_ttl_established_count ${port}`).trim();
      assert.strictEqual(before, "0", "no client connected yet — must report 0, not empty/unknown");

      const client = net.createConnection({ host: "127.0.0.1", port });
      await new Promise((resolve, reject) => {
        client.on("connect", resolve);
        client.on("error", reject);
      });
      // Give Windows' connection table a moment to reflect the new socket.
      sleepMs(500);
      const during = runBash(dir, `idle_ttl_established_count ${port}`).trim();
      assert.strictEqual(during, "1", "exactly one held client connection must be counted");

      client.destroy();
      sleepMs(500);
      const after = runBash(dir, `idle_ttl_established_count ${port}`).trim();
      assert.strictEqual(after, "0", "count must drop back to 0 immediately after the client disconnects");

      srv.close();
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
})();

// --- 2. idle_ttl_run_loop: already-dead server pid — exit, no kill/dispose --
(() => {
  test("idle_ttl_run_loop exits immediately when the server pid is already dead (no dispose recorded)", () => {
    const dir = mkSkillDir();
    try {
      const deadPid = process.pid + 500000;
      const pidfile = path.join(dir, "run", "codex-app-server.fakehash.pid");
      fs.writeFileSync(pidfile, `${deadPid}\n`);
      runBash(
        dir,
        `idle_ttl_run_loop 1 ${deadPid} "$SKILL_DIR/run/codex-app-server.fakehash.pid" 1 1`,
        { timeoutMs: 10000 },
      );
      const lines = manifestLines(dir);
      assert.strictEqual(lines.length, 0, "a dead server pid must produce zero manifest activity — gc.sh's own reaper owns that case, not this loop");
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
})();

// --- 3. idle_ttl_run_loop: superseded pidfile — exit without touching -------
(() => {
  test("idle_ttl_run_loop exits without killing when the pidfile now names a DIFFERENT (newer) server pid", async () => {
    const dir = mkSkillDir();
    let srv;
    try {
      srv = await listenOnce();
      const port = srv.address().port;
      const ourPid = process.pid; // alive for the duration of this test
      const pidfile = path.join(dir, "run", "codex-app-server.fakehash.pid");
      // Pidfile names a DIFFERENT pid than what we pass as server_pid — simulates
      // a newer codex-monitor.sh invocation having replaced the record.
      fs.writeFileSync(pidfile, `${ourPid + 1}\n`);
      runBash(
        dir,
        `idle_ttl_run_loop ${port} ${ourPid} "$SKILL_DIR/run/codex-app-server.fakehash.pid" 1 1`,
        { timeoutMs: 10000 },
      );
      const lines = manifestLines(dir);
      assert.strictEqual(lines.length, 0, "superseded loop must not record any dispose for the server it no longer owns");
      assert.ok(fs.existsSync(pidfile), "superseded loop must not remove the (now-someone-else's) pidfile");
    } finally {
      if (srv) srv.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
})();

// --- 4. idle_ttl_run_loop: real TTL expiry with zero held connections -------
(() => {
  test("idle_ttl_run_loop kills the server and records manifest dispose after TTL with zero held connections", async () => {
    const dir = mkSkillDir();
    let srv;
    let serverPid;
    try {
      srv = await listenOnce();
      const port = srv.address().port;
      // MSYS-space dummy server (see spawnMsysDummyServer's doc comment): a
      // Node child_process.spawn() pid would NOT work here — it is a
      // Windows-native pid invisible to plain `kill -0`, which is exactly
      // what idle_ttl_run_loop's own server-liveness check uses (mirroring
      // codex-monitor.sh's own server_bg="$!" of a plain, non-nohup `&`).
      serverPid = spawnMsysDummyServer(dir);
      assert.ok(msysPidAlive(serverPid), "sanity check: the dummy msys server must be alive before the loop runs");

      const pidfile = path.join(dir, "run", "codex-app-server.fakehash.pid");
      fs.writeFileSync(pidfile, `${serverPid}\n`);

      // ttl=2s, poll=1s: no client ever connects to srv, so established count
      // stays 0 every poll — the loop must break out after ~2s and kill the
      // dummy server.
      runBash(
        dir,
        `idle_ttl_run_loop ${port} ${serverPid} "$SKILL_DIR/run/codex-app-server.fakehash.pid" 2 1`,
        { timeoutMs: 15000 },
      );

      const lines = manifestLines(dir);
      const disposeLines = lines.filter((l) => l.event === "dispose" && l.kind === "process");
      assert.strictEqual(disposeLines.length, 1, "exactly one dispose line must be recorded for the idle-reaped server");
      assert.strictEqual(disposeLines[0].id.pid, String(serverPid));
      assert.ok(!fs.existsSync(pidfile), "server pidfile must be removed once reaped");

      assert.strictEqual(msysPidAlive(serverPid), false, "the idle server process must actually be killed, not just have its pidfile removed");
    } finally {
      if (srv) srv.close();
      if (serverPid) killMsysPid(serverPid); // no-op if already reaped — expected in the success path
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
})();

// --- 5. idle_ttl_run_loop: held connection prevents reap --------------------
(() => {
  test("idle_ttl_run_loop does NOT kill the server while a client keeps a connection held through the TTL window", async () => {
    const dir = mkSkillDir();
    let srv;
    let serverPid;
    let client;
    let loopProc;
    try {
      srv = await listenOnce();
      const port = srv.address().port;
      client = net.createConnection({ host: "127.0.0.1", port });
      await new Promise((resolve, reject) => {
        client.on("connect", resolve);
        client.on("error", reject);
      });

      // MSYS-space dummy server — see spawnMsysDummyServer's doc comment /
      // test 4's same rationale (a Node-spawned pid would make idle_ttl_run_loop's
      // OWN `kill -0 "$server_pid"` liveness check report "dead" on the very
      // first poll tick, making this test pass for the wrong reason: "no
      // dispose because the loop exited early", not "no dispose because the
      // held connection worked").
      serverPid = spawnMsysDummyServer(dir);
      assert.ok(msysPidAlive(serverPid), "sanity check: the dummy msys server must be alive before the loop runs");
      const pidfile = path.join(dir, "run", "codex-app-server.fakehash.pid");
      fs.writeFileSync(pidfile, `${serverPid}\n`);

      // ttl=2s, poll=1s: run the loop in the background for ~3.5s (longer than
      // the TTL) then confirm it did NOT exit/kill — the loop only exits on
      // TTL expiry (blocked here by the held connection) or a dead/superseded
      // server (neither applies), so surviving past the TTL window with the
      // dummy server still alive and no dispose recorded proves the held
      // connection worked.
      loopProc = spawn(
        bash,
        [
          "-c",
          `set -euo pipefail
SKILL_DIR=${bashQuote(dir)}
source "$SKILL_DIR/scripts/lib/compat.sh"
source "$SKILL_DIR/scripts/lib/instance-id.sh"
source "$SKILL_DIR/scripts/lib/manifest.sh"
source "$SKILL_DIR/scripts/lib/gc.sh"
source "$SKILL_DIR/scripts/lib/idle-ttl.sh"
idle_ttl_run_loop ${port} ${serverPid} "$SKILL_DIR/run/codex-app-server.fakehash.pid" 2 1`,
        ],
        { stdio: "ignore", env: bashEnv() },
      );

      await new Promise((resolve) => setTimeout(resolve, 3500));

      const lines = manifestLines(dir);
      const disposeLines = lines.filter((l) => l.event === "dispose" && l.kind === "process");
      assert.strictEqual(disposeLines.length, 0, "a held connection through the whole TTL window must prevent any dispose");
      assert.ok(fs.existsSync(pidfile), "server pidfile must survive while a connection is held");
      assert.strictEqual(msysPidAlive(serverPid), true, "the server process must still be running — held connection must have prevented the kill");
    } finally {
      if (client) client.destroy();
      if (srv) srv.close();
      if (loopProc) {
        try {
          loopProc.kill();
        } catch (_) {
          // best-effort
        }
      }
      if (serverPid) killMsysPid(serverPid);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
})();

// --- 6. gc.sh: idle-ttl pidfile reaper + glob-overlap guard -----------------
(() => {
  test("agmsg_gc_codex_idle_ttl_pidfiles reaps a dead reaper pidfile and leaves a live confirmed one alone; app-server reaper does not touch idle-ttl pidfiles", () => {
    const dir = mkSkillDir();
    let liveReaperPid;
    try {
      const runDir = path.join(dir, "run");

      // Dead reaper pidfile (bogus msys pid).
      const deadReaperPid = process.pid + 500000;
      fs.writeFileSync(path.join(runDir, "codex-app-server.deadhash.idle-ttl.pid"), `${deadReaperPid}\n`);
      fs.writeFileSync(path.join(runDir, "codex-app-server.deadhash.idle-ttl.log"), "stale log\n");

      // Live reaper pidfile — a real long-lived process whose cmdline contains
      // "idle_ttl_run_loop" (mirrors codex-monitor.sh's `bash -c "...
      // idle_ttl_run_loop ..."` launch shape, confirmed empirically in WP2 to
      // put the full script text into cmdline).
      //
      // MSYS-space pid, NOT a Node child_process.spawn() pid: confirmed by
      // direct repro while building this test file that a `bash.exe` process
      // launched via Node's spawn() gets a Windows-native pid invisible to a
      // separate MSYS bash's `kill -0` — the exact same msys/native split
      // documented throughout manifest.sh, just one layer removed (it's true
      // of ANY process Node spawns directly, not only node children). gc.sh's
      // agmsg_gc_codex_idle_ttl_pidfiles liveness check is explicitly msys-space
      // (kill -0, matching codex-monitor.sh's own reaper launch — see
      // codex-monitor.sh's PID STABILITY NOTE), so the live fixture here must
      // be a REAL msys pid or this assertion would silently test the wrong
      // liveness space. Reproduce it via spawnMsysDummyServer's same
      // `bash -c "... & echo $!"` pattern, with the marker text and a `while`
      // loop (not a bare `sleep`, which would get exec-optimized away and lose
      // the marker from cmdline — same reasoning as spawnMsysDummyServer).
      const liveReaperPidStr = execFileSync(
        bash,
        ["-c", "(idle_ttl_run_loop_MARKER=1; while :; do sleep 5; done) </dev/null >/dev/null 2>&1 & disown; echo $!"],
        { encoding: "utf8", env: bashEnv() },
      ).trim();
      liveReaperPid = Number(liveReaperPidStr);
      sleepMs(400);
      assert.ok(msysPidAlive(liveReaperPid), "sanity check: the dummy live reaper must be a real, kill -0-visible msys pid");
      fs.writeFileSync(path.join(runDir, "codex-app-server.livehash.idle-ttl.pid"), `${liveReaperPid}\n`);

      // A REAL app-server pidfile too, to prove the app-server reaper's own
      // glob does not also try to interpret the idle-ttl pidfiles it must skip
      // (see gc.sh's NOTE on this exact overlap).
      const appServerDeadPid = process.pid + 500001;
      fs.writeFileSync(path.join(runDir, "codex-app-server.deadhash.pid"), `${appServerDeadPid}\n`);

      const appServerReaped = runBash(dir, `agmsg_gc_codex_app_server_pidfiles`).trim();
      assert.strictEqual(appServerReaped, "1", "app-server reaper must reap exactly the ONE real app-server pidfile, not the idle-ttl ones sharing its glob prefix");
      assert.ok(
        fs.existsSync(path.join(runDir, "codex-app-server.deadhash.idle-ttl.pid")),
        "app-server reaper must NOT have touched the dead idle-ttl pidfile — that is idle-ttl's own reaper's job",
      );
      assert.ok(
        fs.existsSync(path.join(runDir, "codex-app-server.livehash.idle-ttl.pid")),
        "app-server reaper must NOT have touched the live idle-ttl pidfile either",
      );

      const idleTtlReaped = runBash(dir, `agmsg_gc_codex_idle_ttl_pidfiles`).trim();
      assert.strictEqual(idleTtlReaped, "1", "idle-ttl reaper must reap exactly the dead reaper pidfile");
      assert.ok(
        !fs.existsSync(path.join(runDir, "codex-app-server.deadhash.idle-ttl.pid")),
        "dead reaper pidfile must be removed",
      );
      assert.ok(
        !fs.existsSync(path.join(runDir, "codex-app-server.deadhash.idle-ttl.log")),
        "dead reaper's log must be removed alongside its pidfile",
      );
      assert.ok(
        fs.existsSync(path.join(runDir, "codex-app-server.livehash.idle-ttl.pid")),
        "live, cmdline-confirmed reaper pidfile must survive gc",
      );
    } finally {
      if (liveReaperPid) killMsysPid(liveReaperPid);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
})();

// --- 7. native-pid liveness fix: codex-bridge-launcher.sh / _session-start.sh
(() => {
  test("codex-bridge-launcher.sh's bridge-reuse check now detects a LIVE native-pid bridge via _agmsg_pid_alive (was: always kill -0 'dead')", () => {
    const dir = mkSkillDir();
    let liveChild;
    try {
      // Simulate exactly what codex-bridge.js's writeMeta() records: a
      // Windows-native pid from a nohup-wrapped node child (this is the exact
      // shape WP1 found broken: bash's own kill -0 against this pid always
      // reports "dead" even though the process is alive).
      liveChild = spawn(process.execPath, ["-e", "setTimeout(()=>{}, 30000)"]);
      sleepMs(400);
      const nativePid = liveChild.pid;

      // Before the fix this repo shipped, `kill -0 $nativePid` from bash
      // reliably reported dead for a genuinely-alive native pid — that is
      // the WP1-documented bug this WP2 fix addresses. Confirm the OLD
      // check's failure mode still reproduces (regression canary: if this
      // assertion ever starts failing, MSYS's kill -0 semantics have changed
      // underneath this whole fix and the fix should be re-evaluated).
      const oldCheckSaysAlive = runBash(dir, `kill -0 ${nativePid} 2>/dev/null && echo yes || echo no`).trim();
      assert.strictEqual(oldCheckSaysAlive, "no", "sanity check: plain kill -0 on a native pid must still misreport dead (this is exactly the bug WP1 found and WP2 fixes) — if this now says yes, MSYS semantics changed and the fix rationale should be revisited");

      // The FIXED check (_agmsg_pid_alive, what codex-bridge-launcher.sh and
      // _session-start.sh now call) must correctly report this pid as alive.
      const newCheckSaysAlive = runBash(dir, `_agmsg_pid_alive ${nativePid} 2>/dev/null && echo yes || echo no`).trim();
      assert.strictEqual(newCheckSaysAlive, "yes", "_agmsg_pid_alive must correctly detect the live native-pid bridge process that kill -0 misses");
    } finally {
      try {
        if (liveChild) liveChild.kill();
      } catch (_) {
        // best-effort
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
})();

// --- 8. end-to-end: codex-monitor.sh actually wires up an idle-ttl reaper ---
// Uses the SAME fake-codex pattern as tests/test_codex_monitor.bats (a fake
// "$REAL_CODEX" that answers --version and app-server --listen with a real
// python3-backed loopback listener, and logs any other invocation instead of
// exec'ing a real codex/Codex Desktop — nothing here starts a real codex.exe).
// Runs codex-monitor.sh exactly as production would (no internals invoked
// directly) and confirms it leaves behind a LIVE idle-ttl reaper pidfile
// whose cmdline names the right port/server-pid/pidfile/TTL/poll — i.e. the
// wiring in codex-monitor.sh itself (not just idle-ttl.sh in isolation) does
// what WP2's brief asked for.
(() => {
  test("codex-monitor.sh (full script, fake codex) starts a live idle-ttl reaper bound to the real app-server it launched", () => {
    let python3Available = true;
    try {
      execFileSync("python3", ["--version"], { stdio: "ignore" });
    } catch (_) {
      python3Available = false;
    }
    if (!python3Available) {
      console.log("  # skipped: python3 not available (same fake-codex dependency as tests/test_codex_monitor.bats)");
      return;
    }

    const testDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-codex-monitor-e2e-"));
    const skillDir = path.join(testDir, "skill");
    const projectDir = path.join(testDir, "project");
    let serverPid;
    let reaperPid;
    try {
      fs.mkdirSync(path.join(skillDir, "run"), { recursive: true });
      fs.mkdirSync(projectDir, { recursive: true });
      copyDirSync(path.join(repo, "scripts"), path.join(skillDir, "scripts"));

      const fakeCodex = path.join(testDir, "real-codex");
      // The app-server listener is a SEPARATE .py file invoked via `exec python3
      // <file>`, not a `python3 - <<'PY' ... PY` heredoc run as a plain (non-exec)
      // child, and deliberately does NOT poll its ppid to self-exit (contrast with
      // this same fixture elsewhere in this file / test_codex_monitor.bats's fake
      // codex, both of which use the heredoc+ppid-poll shape). Both differences
      // are load-bearing, confirmed by direct repro while chasing this WP2-fix's
      // Blocking-3 (residual e2e processes):
      //   - Piping a heredoc into `python3 -` makes MSYS bash fork() a SECOND,
      //     independent bash.exe Windows process to feed it (confirmed via
      //     Get-CimInstance: two "bash.exe ... real-codex app-server ..." entries,
      //     parent+child, ~20ms apart) — this script's own `$!`/SERVER_PID only
      //     ever names ONE of the two, so `kill $SERVER_PID` leaves the other
      //     Windows process (and its python3 grandchild) as an orphan no cleanup
      //     path in this file ever targets. `exec python3 <file>` REPLACES the
      //     bash process (no fork, one Windows process total), which is exactly
      //     codex-monitor.sh's own real-`codex`-CLI assumption: `$REAL_CODEX`
      //     execs straight through to a single process, never forks a sibling.
      //   - A ppid-poll self-exit is redundant with (and, empirically, LESS
      //     reliable than) this test's own kill-by-pid teardown once exec is used:
      //     with exec, `kill $SERVER_PID` (this file's own cleanup, and the SAME
      //     msys pid production's idle-ttl reaper / stop_codex_bridge kill) reaps
      //     the whole thing in one shot, so the extra self-exit polling loop is
      //     one less thing that can itself leave a listener spinning if a test
      //     assertion throws between launch and teardown.
      const listenerScript = path.join(testDir, "fake-app-server-listener.py");
      fs.writeFileSync(
        listenerScript,
        `import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16); s.settimeout(0.2)
print("codex app-server (WebSockets)")
print("  listening on: ws://127.0.0.1:%d" % s.getsockname()[1]); sys.stdout.flush()
while True:
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
`,
      );
      fs.writeFileSync(
        fakeCodex,
        `#!/usr/bin/env bash
case "\${1:-}" in
  --version)
    echo "codex-cli 0.142.2"
    exit 0
    ;;
  app-server)
    exec python3 ${bashQuote(listenerScript)}
    ;;
  *)
    printf 'plain-codex' >> "$CALL_LOG"
    for a in "$@"; do printf ' <%s>' "$a" >> "$CALL_LOG"; done
    printf '\\n' >> "$CALL_LOG"
    ;;
esac
`,
      );
      fs.chmodSync(fakeCodex, 0o755);
      const callLog = path.join(testDir, "calls.log");
      fs.writeFileSync(callLog, "");

      execFileSync(
        bash,
        [path.join(skillDir, "scripts", "drivers", "types", "codex", "codex-monitor.sh"),
          "--project", projectDir, "--codex-command", "codex", "--", "--foo"],
        {
          encoding: "utf8",
          timeout: 15000,
          env: {
            ...bashEnv(),
            AGMSG_REAL_CODEX: fakeCodex,
            AGMSG_CODEX_BRIDGE_LAUNCHER_CMD: "/bin/true",
            CALL_LOG: callLog,
          },
        },
      );

      const runDir = path.join(skillDir, "run");
      const pidFiles = fs.readdirSync(runDir).filter((f) => f.startsWith("codex-app-server.") && f.endsWith(".pid") && !f.includes("idle-ttl"));
      assert.strictEqual(pidFiles.length, 1, "codex-monitor.sh must have recorded exactly one app-server pidfile");
      const hash = pidFiles[0].replace(/^codex-app-server\./, "").replace(/\.pid$/, "");

      const serverPidFile = path.join(runDir, `codex-app-server.${hash}.pid`);
      const idleTtlPidFile = path.join(runDir, `codex-app-server.${hash}.idle-ttl.pid`);
      assert.ok(fs.existsSync(idleTtlPidFile), "codex-monitor.sh must have started an idle-ttl reaper pidfile for the app-server it launched");

      serverPid = fs.readFileSync(serverPidFile, "utf8").trim();
      reaperPid = fs.readFileSync(idleTtlPidFile, "utf8").trim();
      assert.ok(msysPidAlive(Number(serverPid)), "the fake app-server process must actually be running");
      assert.ok(msysPidAlive(Number(reaperPid)), "the idle-ttl reaper process must actually be running");

      const reaperCmd = execFileSync(bash, ["-c", `cat /proc/${reaperPid}/cmdline 2>/dev/null | tr '\\0' ' '`], { encoding: "utf8", env: bashEnv() });
      assert.match(reaperCmd, /idle_ttl_run_loop/, "reaper cmdline must contain the idle_ttl_run_loop call");
      // Compare basename only, not the full path: bash's own /proc/<pid>/cmdline
      // reports the POSIX (forward-slash) form of the pidfile path it was
      // invoked with, while Node's path.join above produced a Windows
      // backslash-separated serverPidFile — same file, different separator, so
      // a full-string compare would spuriously fail on Windows.
      assert.ok(reaperCmd.includes(path.basename(serverPidFile)), "reaper cmdline must reference the SAME server pidfile codex-monitor.sh recorded");
      assert.ok(reaperCmd.includes(" 900 30"), "reaper cmdline must carry the default TTL(900s)/poll(30s) codex-monitor.sh passed");
    } finally {
      if (reaperPid) killMsysPid(Number(reaperPid));
      if (serverPid) killMsysPid(Number(serverPid));
      // Belt-and-suspenders beyond the two msys-pid kills above: sweep any
      // Windows process whose command line still names THIS test's own
      // testDir (a fresh mkdtempSync path, unique to this run — never matches
      // an unrelated process). Covers the same process-tree-split hazard the
      // fakeCodex script's `exec python3 <file>` fix above addresses (a
      // forked sibling Windows process from a heredoc-fed child would carry
      // this testDir in its own command line too), so a regression in that
      // fix — or any other unanticipated child this fixture spawns — still
      // gets reaped here rather than leaking, instead of relying solely on
      // the exec fix never regressing. Windows-only (this file's whole
      // premise is a Windows Git Bash repro); a non-Windows CI runner reaping
      // via msysPidAlive/killMsysPid above is enough there.
      if (process.platform === "win32") {
        try {
          const testDirBasename = path.basename(testDir);
          const psScript = `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*${testDirBasename}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`;
          execFileSync("powershell.exe", ["-NoProfile", "-Command", psScript], { stdio: "ignore", timeout: 10000 });
        } catch (_) {
          // best-effort — the msys-pid kills above are the primary teardown path
        }
      }
      fs.rmSync(testDir, { recursive: true, force: true });
    }
  });
})();

function copyDirSync(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDirSync(s, d);
    else fs.copyFileSync(s, d);
  }
}

// Self-check: after every test's own try/finally teardown has run, confirm
// NONE of this file's disposable test dirs (agmsg-idle-ttl-test-* from
// mkSkillDir, agmsg-codex-monitor-e2e-* from the end-to-end test) still has a
// live Windows process naming it on the command line. This is the leak this
// WP2-fix was asked to close (residual fake app-server / reaper processes
// surviving a `node tests/test-idle-ttl.cjs` run) — asserting it here, once,
// after the full suite, catches a regression in ANY individual test's
// teardown (not just the e2e test's own belt-and-suspenders sweep above),
// without hardcoding assumptions about which test leaked. Windows-only: the
// whole premise of this residual-process check is Windows Git Bash process
// tree behavior (see the exec-vs-heredoc fork finding documented at the fake
// codex fixture above); a non-Windows CI runner relies on its own
// msysPidAlive/killMsysPid-equivalent teardown per test instead.
function residualTestProcesses() {
  if (process.platform !== "win32") return [];
  try {
    // Excludes ITSELF: this powershell.exe's own CommandLine necessarily
    // contains the same 'agmsg-idle-ttl-test-|agmsg-codex-monitor-e2e-'
    // literal (it is the -match pattern below), which would otherwise always
    // self-match and false-positive on every run. Filtering by Name != both
    // powershell.exe AND pwsh.exe (PowerShell 7, which is what actually runs
    // this on this dev box) excludes the query process itself without
    // excluding a genuinely leaked bash.exe/python3.exe/python3.13.exe fixture
    // process — none of which are ever named powershell.exe or pwsh.exe.
    const psScript =
      "Get-CimInstance Win32_Process | " +
      "Where-Object { $_.CommandLine -match 'agmsg-idle-ttl-test-|agmsg-codex-monitor-e2e-' -and $_.Name -ne 'powershell.exe' -and $_.Name -ne 'pwsh.exe' } | " +
      "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress";
    const out = execFileSync("powershell.exe", ["-NoProfile", "-Command", psScript], { encoding: "utf8", timeout: 10000 }).trim();
    if (!out) return [];
    const parsed = JSON.parse(out);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch (_) {
    // best-effort — a failure to query must not itself fail the suite (this
    // check is a regression guard, not the tests' own correctness assertions)
    return [];
  }
}

runAll().then(() => {
  const residual = residualTestProcesses();
  if (residual.length > 0) {
    failures++;
    console.log("not ok - self-check: zero residual test processes after the suite completes");
    for (const p of residual) {
      console.log(`  leaked pid=${p.ProcessId} cmdline=${p.CommandLine}`);
    }
  } else {
    console.log("ok - self-check: zero residual test processes after the suite completes");
  }

  if (failures > 0) {
    console.log(JSON.stringify({ ok: false, failures }));
    process.exit(1);
  }
  console.log(JSON.stringify({ ok: true }));
});
