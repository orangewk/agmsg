#!/usr/bin/env node
"use strict";
//
// test-waker-lifecycle.cjs — direct-execution regression test for the
// companion-waker PoC's lifecycle wiring (orangewk/agmsg#8, WP3a).
//
// Scope: this test does NOT touch the PoC's wake-decision logic (mailbox
// delivery, adapter turn/start protocol — already covered by
// tests/poc/test-delivery-supervisor*.cjs / tests/poc/test-*-adapter*.cjs).
// It covers ONLY the lifecycle wiring added on top:
//   1. codex-app-server-owner.js: start()/stop() record manifest.jsonl
//      create/dispose lines for both the owned app-server process AND its
//      pid/port/endpoint state-file set.
//   2. delivery-supervisor.js: start()/stop() record manifest.jsonl
//      create/dispose lines for both the supervisor process itself AND its
//      port/lock/mailbox/state/events/adapter-log state-file set.
//   3. gc.sh: agmsg_gc_poc_waker_app_server_owner_pidfiles and
//      agmsg_gc_poc_waker_delivery_supervisor_pidfiles reap a DEAD record and
//      leave a LIVE, cmdline-confirmed one alone.
//   4. delivery.sh: stop_poc_waker kills a LIVE, confirmed owner/supervisor
//      process, records manifest dispose, and removes the state-file set —
//      the `delivery.sh set off codex` teardown path (via
//      scripts/drivers/types/codex/_delivery.sh's agmsg_delivery_on_disable).
//   5. delivery.sh: stop_codex_bridge actually stops the codex-bridge.js
//      process it finds alive (orangewk/agmsg#8 follow-up: bpid is a
//      Windows-native pid — codex-bridge.js's writeMeta() writes its own
//      process.pid, not the launcher's `nohup ... &` bash $! — and a plain
//      `kill "$bpid"` (MSYS pid space) silently failed against it even though
//      `delivery.sh set off codex` reported "Stopped 1 Codex bridge"; fixed by
//      extracting stop_poc_waker's existing native-kill helper, previously
//      private to that function, into a shared _agmsg_kill_native_pid both
//      functions now call).
//
// Run via plain `node`, not bats — same reasoning as tests/test-manifest-gc.cjs
// and tests/test-idle-ttl.cjs (the full bats suite hangs on this Windows dev
// box; this file follows the same node-direct pattern already established).
//
// Fake codex fixture: a `.ps1` script (NOT a bash/python fixture) because
// codex-app-server-owner.js's spawnCodex() has exactly two code paths —
// native-exe direct spawn, or `powershell.exe -File <script>.ps1` for a
// `.ps1` codex path (mirroring its real Windows install-time fallback,
// AppData\Roaming\npm\codex.ps1). Using the SAME code path this script
// already has, rather than inventing a spawn variant of our own, exercises
// exactly what production would run.

const assert = require("assert");
const { execFileSync, spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const bash = findBash();

// See tests/test-idle-ttl.cjs's identical helper for the full rationale: a
// bash.exe spawned from a non-Git-Bash parent (PowerShell/cmd.exe) inherits
// that parent's PATH/MSYSTEM, not ones bash.exe would set for itself, which
// breaks compat.sh's `uname` / gc.sh's `rm` / MSYSTEM-gated code paths unless
// this test explicitly repairs both for every spawned bash child.
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

function bashQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function mkSkillDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-waker-lifecycle-test-"));
  fs.mkdirSync(path.join(dir, "scripts", "lib"), { recursive: true });
  fs.mkdirSync(path.join(dir, "run"), { recursive: true });
  for (const f of ["manifest.sh", "gc.sh", "compat.sh", "instance-id.sh"]) {
    fs.copyFileSync(path.join(repo, "scripts", "lib", f), path.join(dir, "scripts", "lib", f));
  }
  return dir;
}

function runBash(skillDir, script, opts = {}) {
  const wrapped = `
set -euo pipefail
SKILL_DIR=${bashQuote(skillDir)}
source "$SKILL_DIR/scripts/lib/compat.sh"
source "$SKILL_DIR/scripts/lib/instance-id.sh"
source "$SKILL_DIR/scripts/lib/manifest.sh"
source "$SKILL_DIR/scripts/lib/gc.sh"
${script}
`;
  return execFileSync(bash, ["-c", wrapped], { encoding: "utf8", timeout: opts.timeoutMs || 20000, env: bashEnv() });
}

function manifestLines(skillDir) {
  const p = path.join(skillDir, "run", "manifest.jsonl");
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, "utf8").split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

let failures = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures++;
    console.log(`not ok - ${name}`);
    console.log(String(error && error.stack ? error.stack : error).split("\n").map((l) => `  ${l}`).join("\n"));
  }
}

async function asyncTest(name, fn) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures++;
    console.log(`not ok - ${name}`);
    console.log(String(error && error.stack ? error.stack : error).split("\n").map((l) => `  ${l}`).join("\n"));
  }
}

// Fake codex fixture (.ps1 — see file header for why): --version prints a
// fake version; app-server binds a real loopback TCP port, prints the exact
// "listening on: ws://..." line codex-app-server-owner.js's waitPort() and
// production's own codex-monitor.sh both key on, then blocks forever so a
// liveness check (tasklist/CIM) sees a real, running process — killed only by
// this test's own teardown (owner.js stop() / taskkill).
function writeFakeCodexPs1(dir) {
  const ps1 = path.join(dir, "fake-codex.ps1");
  fs.writeFileSync(
    ps1,
    [
      "param()",
      'if ($args[0] -eq "--version") { Write-Output "codex-cli 0.142.2"; exit 0 }',
      'if ($args[0] -eq "app-server") {',
      // codex-app-server-owner.js's waitPort() polls the SPECIFIC port it
      // chose via --listen ws://127.0.0.1:<port> (see start()'s own freePort()
      // call) — it does not re-read the log for a different port the way
      // codex-monitor.sh's bash-side loop does. So this fixture must bind
      // THAT exact requested port, not pick its own free one (an earlier
      // version of this fixture picked its own port via TcpListener(0),
      // which reliably mismatched the port the owner was actually polling
      // and made every start() call time out).
      '  $listenArg = $args | Where-Object { $_ -like "ws://*" } | Select-Object -First 1',
      '  $requestedPort = [int]($listenArg -replace ".*:(\\d+)$", \'$1\')',
      "  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $requestedPort)",
      "  $listener.Start()",
      '  Write-Output "codex app-server (WebSockets)"',
      '  Write-Output "  listening on: ws://127.0.0.1:$requestedPort"',
      "  while ($true) { Start-Sleep -Seconds 1 }",
      "}",
      "",
    ].join("\r\n"),
  );
  return ps1;
}

function residualWakerProcesses(marker) {
  if (process.platform !== "win32") return [];
  try {
    const psScript =
      "Get-CimInstance Win32_Process | " +
      `Where-Object { $_.CommandLine -match '${marker}' -and $_.Name -ne 'powershell.exe' -and $_.Name -ne 'pwsh.exe' } | ` +
      "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress";
    const out = execFileSync("powershell.exe", ["-NoProfile", "-Command", psScript], { encoding: "utf8", timeout: 10000 }).trim();
    if (!out) return [];
    const parsed = JSON.parse(out);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch (_) {
    return [];
  }
}

async function runAll() {
  // --- 1. codex-app-server-owner.js: start()/stop() manifest wiring --------
  await asyncTest("codex-app-server-owner.js start() records process + state-file create lines", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-waker-lifecycle-test-owner-"));
    const runDir = path.join(dir, "poc-run");
    const ps1 = writeFakeCodexPs1(dir);
    const ownerScript = path.join(repo, "scripts", "poc", "codex-app-server-owner.js");
    const env = { ...process.env, AGMSG_SKILL_DIR: dir };
    try {
      const startOut = execFileSync(
        process.execPath,
        [ownerScript, "start", "--run-dir", runDir, "--codex", ps1],
        { encoding: "utf8", env, timeout: 15000 },
      );
      const started = JSON.parse(startOut);
      assert.strictEqual(started.ok, true, `start failed: ${startOut}`);
      assert.ok(started.pid > 0, "owner start should report the app-server child pid");

      const lines = manifestLines(dir);
      const createProcess = lines.find((l) => l.event === "create" && l.kind === "process" && l.id.pid === String(started.pid));
      assert.ok(createProcess, "manifest should have a create/process line for the owned app-server pid");
      assert.strictEqual(createProcess.id.pidSpace, "native", "owner-spawned app-server child pid must be recorded as native pidSpace");
      const createStateFile = lines.find((l) => l.event === "create" && l.kind === "state-file");
      assert.ok(createStateFile, "manifest should have a create/state-file line for the owner's pid/port/endpoint/log set");
      assert.match(createStateFile.id.path, /codex-app-server\.pid$/, "state-file entry should point at the owner's pidfile");

      const stopOut = execFileSync(process.execPath, [ownerScript, "stop", "--run-dir", runDir], { encoding: "utf8", env, timeout: 15000 });
      const stopped = JSON.parse(stopOut);
      assert.strictEqual(stopped.ok, true, `stop failed: ${stopOut}`);
      assert.strictEqual(stopped.stopped, true, "stop() should report it actually stopped the owned process");

      const linesAfterStop = manifestLines(dir);
      const disposeProcess = linesAfterStop.find((l) => l.event === "dispose" && l.kind === "process" && l.id.pid === String(started.pid));
      assert.ok(disposeProcess, "manifest should have a dispose/process line after stop()");
      const disposeStateFile = linesAfterStop.find((l) => l.event === "dispose" && l.kind === "state-file");
      assert.ok(disposeStateFile, "manifest should have a dispose/state-file line after stop()");

      assert.ok(!fs.existsSync(path.join(runDir, "codex-app-server.pid")), "pidfile should be removed after stop()");
    } finally {
      // Belt-and-suspenders: stop() already ran above, but if an assertion threw
      // between start() and stop(), the owned PowerShell/app-server process
      // could still be alive — sweep by the unique run-dir path in its cmdline.
      try {
        execFileSync(
          process.execPath,
          [path.join(repo, "scripts", "poc", "codex-app-server-owner.js"), "stop", "--run-dir", runDir],
          { encoding: "utf8", env, timeout: 10000 },
        );
      } catch (_) {
        // already stopped, or never started — fine
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  // --- 2. delivery-supervisor.js: start()/stop() manifest wiring -----------
  await asyncTest("delivery-supervisor.js start() records process + state-file create lines", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-waker-lifecycle-test-supervisor-"));
    const runDir = path.join(dir, "poc-run");
    const project = path.join(dir, "project");
    fs.mkdirSync(project, { recursive: true });
    const supervisorScript = path.join(repo, "scripts", "poc", "delivery-supervisor.js");
    const env = { ...process.env, AGMSG_SKILL_DIR: dir };
    let proc = null;
    try {
      proc = spawn(process.execPath, [supervisorScript, "start", "--run-dir", runDir, "--project", project, "--heartbeat-timeout-ms", "700", "--poll-ms", "100"], {
        cwd: repo,
        stdio: ["ignore", "pipe", "pipe"],
        env,
      });
      const deadline = Date.now() + 5000;
      let portFile = null;
      while (Date.now() < deadline && !portFile) {
        if (fs.existsSync(runDir)) portFile = fs.readdirSync(runDir).find((n) => n.endsWith(".port"));
        if (!portFile) sleepMs(50);
      }
      assert.ok(portFile, "supervisor port file should appear");

      const lines = manifestLines(dir);
      const createProcess = lines.find((l) => l.event === "create" && l.kind === "process" && l.id.pid === String(proc.pid));
      assert.ok(createProcess, "manifest should have a create/process line for the supervisor's own pid");
      assert.strictEqual(createProcess.id.pidSpace, "native", "supervisor's own pid must be recorded as native pidSpace");
      const createStateFile = lines.find((l) => l.event === "create" && l.kind === "state-file");
      assert.ok(createStateFile, "manifest should have a create/state-file line for the supervisor's port/lock/mailbox/state/events/adapter-log set");
      assert.match(createStateFile.id.path, /\.port$/, "state-file entry should point at the supervisor's port file");

      const stopOut = execFileSync(process.execPath, [supervisorScript, "stop", "--run-dir", runDir, "--project", project], { encoding: "utf8", env, timeout: 10000 });
      const stopped = JSON.parse(stopOut);
      assert.strictEqual(stopped.ok, true, `stop failed: ${stopOut}`);

      const deadline2 = Date.now() + 3000;
      while (proc && !proc.killed && Date.now() < deadline2) sleepMs(50);
      proc = null;

      const linesAfterStop = manifestLines(dir);
      const disposeProcess = linesAfterStop.find((l) => l.event === "dispose" && l.kind === "process" && l.id.pid === String(createProcess.id.pid));
      assert.ok(disposeProcess, "manifest should have a dispose/process line after stop()");
      const disposeStateFile = linesAfterStop.find((l) => l.event === "dispose" && l.kind === "state-file");
      assert.ok(disposeStateFile, "manifest should have a dispose/state-file line after stop()");
    } finally {
      if (proc && !proc.killed) {
        try { proc.kill(); } catch (_) {}
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  // --- 3. gc.sh: waker pidfile reapers --------------------------------------
  test("agmsg_gc_poc_waker_app_server_owner_pidfiles reaps a dead record and leaves a live, confirmed one alone", () => {
    const dir = mkSkillDir();
    try {
      const ownerDir = path.join(dir, "run", "poc-codex-app-server");
      fs.mkdirSync(ownerDir, { recursive: true });

      // Dead case: a pid essentially guaranteed dead (current pid + huge offset).
      const deadPid = process.pid + 500000;
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.pid"), `${deadPid}\n`);
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.port"), "12345\n");
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.endpoint"), "ws://127.0.0.1:12345\n");

      const out = runBash(dir, `agmsg_gc_poc_waker_app_server_owner_pidfiles ${bashQuote(ownerDir)}`);
      assert.strictEqual(out.trim(), "1", "dead owner record should be reaped");
      assert.ok(!fs.existsSync(path.join(ownerDir, "codex-app-server.pid")), "pidfile should be removed");
      assert.ok(!fs.existsSync(path.join(ownerDir, "codex-app-server.port")), "port file should be removed");
      assert.ok(!fs.existsSync(path.join(ownerDir, "codex-app-server.endpoint")), "endpoint file should be removed");
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await asyncTest("agmsg_gc_poc_waker_app_server_owner_pidfiles leaves a LIVE, cmdline-confirmed owner record alone", async () => {
    const dir = mkSkillDir();
    const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-waker-lifecycle-test-gc-owner-"));
    let child = null;
    try {
      const ps1 = writeFakeCodexPs1(fixtureDir);
      // Spawn the SAME shape codex-app-server-owner.js's spawnCodex() uses for a
      // .ps1 codex path, so the live cmdline this test checks against gc.sh's
      // *codex*app-server* match is the real production invocation shape, not
      // an approximation.
      child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, "app-server", "--listen", "ws://127.0.0.1:0"], {
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
      await new Promise((resolve, reject) => {
        let out = "";
        const timer = setTimeout(() => reject(new Error("fake codex did not report a listening port in time")), 5000);
        child.stdout.on("data", (d) => {
          out += d.toString();
          if (out.includes("listening on")) {
            clearTimeout(timer);
            resolve();
          }
        });
      });

      const ownerDir = path.join(dir, "run", "poc-codex-app-server");
      fs.mkdirSync(ownerDir, { recursive: true });
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.pid"), `${child.pid}\n`);
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.port"), "1\n");
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.endpoint"), "ws://127.0.0.1:1\n");

      const cmdlineCheck = runBash(dir, `compat_get_native_cmdline ${child.pid}`).trim();
      assert.match(cmdlineCheck, /codex.*app-server|app-server.*codex/i, `expected the live fake codex cmdline to mention codex+app-server, got: ${cmdlineCheck}`);

      const out = runBash(dir, `agmsg_gc_poc_waker_app_server_owner_pidfiles ${bashQuote(ownerDir)}`);
      assert.strictEqual(out.trim(), "0", "live, confirmed owner record must not be reaped");
      assert.ok(fs.existsSync(path.join(ownerDir, "codex-app-server.pid")), "pidfile of a live confirmed owner record must survive gc");
    } finally {
      if (child && !child.killed) {
        try { execFileSync("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" }); } catch (_) {}
      }
      fs.rmSync(dir, { recursive: true, force: true });
      fs.rmSync(fixtureDir, { recursive: true, force: true });
    }
  });

  test("agmsg_gc_poc_waker_delivery_supervisor_pidfiles reaps a dead record and leaves a live, confirmed one alone", () => {
    const dir = mkSkillDir();
    try {
      const supDir = path.join(dir, "run", "poc-delivery-supervisor");
      fs.mkdirSync(supDir, { recursive: true });

      const deadPid = process.pid + 500000;
      const prefix = path.join(supDir, "supervisor.abc123");
      fs.writeFileSync(`${prefix}.lock`, JSON.stringify({ pid: deadPid, port: 1, project: "C:\\fake\\project" }));
      fs.writeFileSync(`${prefix}.port`, "1\n");
      fs.writeFileSync(`${prefix}.mailbox.jsonl`, "");
      fs.writeFileSync(`${prefix}.state.json`, "{}");
      fs.writeFileSync(`${prefix}.events.log`, "");
      fs.writeFileSync(`${prefix}.adapter.log`, "");

      const out = runBash(dir, `agmsg_gc_poc_waker_delivery_supervisor_pidfiles ${bashQuote(supDir)}`);
      assert.strictEqual(out.trim(), "1", "dead supervisor record should be reaped");
      for (const suffix of [".lock", ".port", ".mailbox.jsonl", ".state.json", ".events.log", ".adapter.log"]) {
        assert.ok(!fs.existsSync(`${prefix}${suffix}`), `${suffix} should be removed`);
      }
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("agmsg_gc_poc_waker_delivery_supervisor_pidfiles leaves a LIVE, cmdline-confirmed supervisor record alone", () => {
    const dir = mkSkillDir();
    const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-waker-lifecycle-test-gc-sup-"));
    // Real nohup-launched node child (mirrors codex-bridge-launcher.sh's own
    // launch shape / tests/test-manifest-gc.cjs's own native-pid simulation
    // rationale): the whole point of pidSpace=native is that liveness/cmdline
    // must be checked via tasklist/CIM, not kill -0/compat_get_cmdline — a
    // plain spawn() here would give a REAL Windows-native pid either way, but
    // this mirrors production's actual "Node reports its own process.pid"
    // shape rather than asserting the distinction only by comment.
    let child = null;
    try {
      child = spawn(process.execPath, ["-e", "/*delivery-supervisor*/ setTimeout(()=>{}, 8000)"]);
      sleepMs(400);
      const nativePid = child.pid;

      const cmdlineCheck = runBash(dir, `compat_get_native_cmdline ${nativePid}`).trim();
      assert.ok(/node/i.test(cmdlineCheck), `expected node in cmdline, got: ${cmdlineCheck}`);

      const supDir = path.join(dir, "run", "poc-delivery-supervisor");
      fs.mkdirSync(supDir, { recursive: true });
      const prefix = path.join(supDir, "supervisor.def456");
      fs.writeFileSync(`${prefix}.lock`, JSON.stringify({ pid: nativePid, port: 1, project: "C:\\fake\\project" }));
      fs.writeFileSync(`${prefix}.port`, "1\n");

      const out = runBash(dir, `agmsg_gc_poc_waker_delivery_supervisor_pidfiles ${bashQuote(supDir)}`);
      assert.strictEqual(out.trim(), "0", "live, confirmed supervisor record must not be reaped");
      assert.ok(fs.existsSync(`${prefix}.lock`), "lock file of a live confirmed supervisor record must survive gc");
    } finally {
      if (child) { try { child.kill(); } catch (_) {} }
      fs.rmSync(dir, { recursive: true, force: true });
      fs.rmSync(fixtureDir, { recursive: true, force: true });
    }
  });

  // --- 4. delivery.sh: stop_poc_waker teardown ------------------------------
  await asyncTest("delivery.sh's stop_poc_waker kills a live confirmed owner + supervisor and records manifest dispose", async () => {
    const dir = mkSkillDir();
    // stop_poc_waker (delivery.sh) needs the FULL scripts/ tree (it sources
    // hash.sh/instance-id.sh/etc via delivery.sh's own top-of-file sourcing),
    // not just the lib/ subset the other gc.sh-only tests copy.
    fs.rmSync(path.join(dir, "scripts"), { recursive: true, force: true });
    copyDirSync(path.join(repo, "scripts"), path.join(dir, "scripts"));
    const runDir = path.join(dir, "run");
    fs.mkdirSync(runDir, { recursive: true });

    const project = path.join(dir, "project");
    fs.mkdirSync(project, { recursive: true });
    const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-waker-lifecycle-test-stopoff-"));

    let ownerChild = null;
    let supervisorProc = null;
    try {
      // Live owner-managed app-server (real fake-codex process, .ps1 shape).
      const ps1 = writeFakeCodexPs1(fixtureDir);
      ownerChild = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, "app-server", "--listen", "ws://127.0.0.1:0"], {
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
      await new Promise((resolve, reject) => {
        let out = "";
        const timer = setTimeout(() => reject(new Error("fake codex did not report a listening port in time")), 5000);
        ownerChild.stdout.on("data", (d) => {
          out += d.toString();
          if (out.includes("listening on")) {
            clearTimeout(timer);
            resolve();
          }
        });
      });
      const ownerDir = path.join(runDir, "poc-codex-app-server");
      fs.mkdirSync(ownerDir, { recursive: true });
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.pid"), `${ownerChild.pid}\n`);
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.port"), "1\n");
      fs.writeFileSync(path.join(ownerDir, "codex-app-server.endpoint"), "ws://127.0.0.1:1\n");

      // Live supervisor process for the SAME project, via the real script (so
      // its cmdline genuinely contains "delivery-supervisor", the substring
      // stop_poc_waker's confirm-before-kill match requires).
      const supervisorScript = path.join(repo, "scripts", "poc", "delivery-supervisor.js");
      const supRunDir = path.join(runDir, "poc-delivery-supervisor");
      supervisorProc = spawn(process.execPath, [supervisorScript, "start", "--run-dir", supRunDir, "--project", project, "--heartbeat-timeout-ms", "5000", "--poll-ms", "200"], {
        cwd: repo,
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, AGMSG_SKILL_DIR: dir },
      });
      const deadline = Date.now() + 5000;
      let portFile = null;
      while (Date.now() < deadline && !portFile) {
        if (fs.existsSync(supRunDir)) portFile = fs.readdirSync(supRunDir).find((n) => n.endsWith(".port"));
        if (!portFile) sleepMs(50);
      }
      assert.ok(portFile, "supervisor port file should appear before stop_poc_waker runs");
      // Manifest already has create lines for both from their own start() —
      // clear it so this test's assertions are only about stop_poc_waker's
      // OWN dispose lines, not a mix with the start()-time create lines.
      fs.writeFileSync(path.join(runDir, "manifest.jsonl"), "");

      // Pull only stop_poc_waker's own definition out of delivery.sh into a
      // SEPARATE FILE, then source that file (delivery.sh itself is a
      // "set -euo pipefail" TOP-LEVEL script keyed on $1 — sourcing it
      // directly would try to run its arg-parsing and exit; this mirrors the
      // "source just the function" convention idle-ttl.sh's own callers use).
      // Deliberately NOT built as a JS template literal containing the
      // extracted bash directly: stop_poc_waker's body is full of braced
      // parameter expansions (${f%.lock}, ${prefix}, etc.) that a JS
      // template literal would try to evaluate as ITS OWN ${...}
      // interpolation — confirmed by direct repro (this test originally used
      // that shape and failed with a wall of "local: not a valid identifier"
      // errors, because half the extracted script's ${...} references had
      // already been silently mangled by the JS engine, not bash, before
      // bash ever saw the string).
      // stop_poc_waker calls _agmsg_kill_native_pid (defined earlier in
      // delivery.sh, shared with stop_codex_bridge — see that helper's own
      // comment for why the two functions now share one native-kill
      // primitive instead of stop_poc_waker keeping a private copy). Extract
      // both definitions, in file order, so the driver script below has
      // everything stop_poc_waker's body actually calls.
      const deliveryShPath = bashQuote(path.join(dir, "scripts", "delivery.sh"));
      const killHelperBody = execFileSync(bash, ["-c", `sed -n '/^_agmsg_kill_native_pid() {/,/^}/p' ${deliveryShPath}`], { encoding: "utf8" });
      const fnBody = killHelperBody + execFileSync(bash, ["-c", `sed -n '/^stop_poc_waker() {/,/^}/p' ${deliveryShPath}`], { encoding: "utf8" });
      const driverScript = path.join(dir, "stop-poc-waker-driver.sh");
      fs.writeFileSync(
        driverScript,
        [
          "set -euo pipefail",
          `SKILL_DIR=${bashQuote(dir)}`,
          'SCRIPT_DIR="$SKILL_DIR/scripts"',
          'RUN_DIR="$SKILL_DIR/run"',
          'source "$SCRIPT_DIR/lib/compat.sh"',
          'source "$SCRIPT_DIR/lib/resolve-project.sh"',
          'source "$SCRIPT_DIR/lib/instance-id.sh"',
          'source "$SCRIPT_DIR/lib/node.sh"',
          'source "$SCRIPT_DIR/lib/hash.sh"',
          'source "$SCRIPT_DIR/lib/type-registry.sh"',
          'source "$SCRIPT_DIR/lib/storage.sh"',
          'source "$SCRIPT_DIR/lib/manifest.sh"',
          fnBody,
          `stop_poc_waker ${bashQuote(project)}`,
        ].join("\n"),
      );
      const out = execFileSync(bash, ["-c", `source ${bashQuote(driverScript)}`], { encoding: "utf8", timeout: 20000, env: bashEnv() });
      assert.strictEqual(out.trim(), "2", `stop_poc_waker should report 2 killed (owner app-server + supervisor), got: ${out}`);

      // Both processes should actually be dead now.
      const deadline2 = Date.now() + 5000;
      let ownerGone = false;
      let supervisorGone = false;
      while (Date.now() < deadline2 && !(ownerGone && supervisorGone)) {
        try { process.kill(ownerChild.pid, 0); } catch (_) { ownerGone = true; }
        try { process.kill(supervisorProc.pid, 0); } catch (_) { supervisorGone = true; }
        if (!(ownerGone && supervisorGone)) sleepMs(200);
      }
      assert.ok(ownerGone, "owner-managed app-server process should be dead after stop_poc_waker");
      assert.ok(supervisorGone, "supervisor process should be dead after stop_poc_waker");

      const lines = manifestLines(dir);
      const disposeProcessLines = lines.filter((l) => l.event === "dispose" && l.kind === "process");
      assert.strictEqual(disposeProcessLines.length, 2, "stop_poc_waker should record exactly 2 process dispose lines");
      assert.ok(disposeProcessLines.every((l) => l.id.pidSpace === "native"), "both dispose lines must use native pidSpace");
      const disposeStateFileLines = lines.filter((l) => l.event === "dispose" && l.kind === "state-file");
      assert.strictEqual(disposeStateFileLines.length, 2, "stop_poc_waker should record exactly 2 state-file dispose lines");

      assert.ok(!fs.existsSync(path.join(runDir, "poc-codex-app-server", "codex-app-server.pid")), "owner pidfile should be removed");
      assert.ok(!fs.existsSync(path.join(supRunDir, portFile)), "supervisor port file should be removed");

      ownerChild = null;
      supervisorProc = null;
    } finally {
      if (ownerChild) {
        try { execFileSync("taskkill.exe", ["/PID", String(ownerChild.pid), "/T", "/F"], { stdio: "ignore" }); } catch (_) {}
      }
      if (supervisorProc) {
        try { supervisorProc.kill(); } catch (_) {}
      }
      fs.rmSync(dir, { recursive: true, force: true });
      fs.rmSync(fixtureDir, { recursive: true, force: true });
    }
  });

  // --- 5. delivery.sh: stop_codex_bridge actually kills the native bpid -----
  await asyncTest("delivery.sh's stop_codex_bridge kills a live native-pid bridge process (regression for the plain-`kill` bug)", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-waker-lifecycle-test-bridgeoff-"));
    // stop_codex_bridge (delivery.sh) needs the FULL scripts/ tree: it shells
    // out to identities.sh (which itself needs lib/resolve-project.sh,
    // lib/storage.sh, lib/registry-lock.sh, and a real sqlite3 + teams/
    // config.json — join.sh below creates that config), same reasoning as
    // the stop_poc_waker driver above.
    copyDirSync(path.join(repo, "scripts"), path.join(dir, "scripts"));
    fs.mkdirSync(path.join(dir, "run"), { recursive: true });
    fs.mkdirSync(path.join(dir, "teams"), { recursive: true });
    fs.mkdirSync(path.join(dir, "db"), { recursive: true });
    execFileSync(bash, [path.join(dir, "scripts", "internal", "init-db.sh")], { encoding: "utf8", env: bashEnv() });

    const project = path.join(dir, "project");
    fs.mkdirSync(project, { recursive: true });
    const home = path.join(dir, "home");
    fs.mkdirSync(home, { recursive: true });
    const env = { ...bashEnv(), HOME: home };

    // Register a codex identity for this project — stop_codex_bridge's own
    // `identities.sh "$project" codex` lookup needs this pair to find the
    // pidfile at all (mirrors tests/test_delivery.bats's own `join.sh team
    // alice codex "$TEST_PROJECT"` setup for its stop_codex_bridge coverage).
    execFileSync(bash, [path.join(dir, "scripts", "join.sh"), "team", "alice", "codex", project], { encoding: "utf8", env });

    let bridgeChild = null;
    try {
      // A real, long-lived Node child stands in for codex-bridge.js: what
      // matters for this regression is ONLY that child.pid is a genuine
      // Windows-native pid. codex-bridge.js binds and reports its own
      // process.pid via writeMeta() — a plain `spawn()` here reports that
      // same native pid, so this exercises the exact "native pid, plain
      // `kill` fails" gap the bug lived in (see _agmsg_kill_native_pid's own
      // comment in delivery.sh for the full mechanism).
      bridgeChild = spawn(process.execPath, ["-e", "setTimeout(()=>{}, 30000)"]);
      await new Promise((resolve) => { sleepMs(300); resolve(); });

      const pidfile = path.join(dir, "run", "codex-bridge.team.alice.pid");
      fs.writeFileSync(pidfile, `${bridgeChild.pid}\n`);
      fs.writeFileSync(path.join(dir, "run", "codex-bridge.team.alice.meta"), `pid=${bridgeChild.pid}\n`);
      fs.writeFileSync(path.join(dir, "run", "codex-bridge.team.alice.log"), "");
      fs.writeFileSync(path.join(dir, "run", "codex-bridge.team.alice.appserver"), "");

      // Confirm the fixture is alive BEFORE calling stop_codex_bridge, so a
      // later "is it dead" check can't pass merely because it was never
      // running.
      let aliveBefore = true;
      try { process.kill(bridgeChild.pid, 0); } catch (_) { aliveBefore = false; }
      assert.ok(aliveBefore, "fixture bridge process should be alive before stop_codex_bridge runs");

      // Pull only stop_codex_bridge's own definition (plus the shared
      // _agmsg_kill_native_pid helper it now calls) out of delivery.sh — same
      // "source just the function" driver pattern as the stop_poc_waker test
      // above (delivery.sh itself is a top-level "set -euo pipefail" script
      // keyed on $1, so sourcing it directly would run its arg-parsing and
      // exit).
      const deliveryShPath = path.join(dir, "scripts", "delivery.sh");
      const fnBody = execFileSync(
        bash,
        ["-c", `sed -n '/^_agmsg_kill_native_pid() {/,/^}/p;/^stop_codex_bridge() {/,/^}/p' ${bashQuote(deliveryShPath)}`],
        { encoding: "utf8" },
      );
      const driverScript = path.join(dir, "stop-codex-bridge-driver.sh");
      fs.writeFileSync(
        driverScript,
        [
          "set -euo pipefail",
          `SKILL_DIR=${bashQuote(dir)}`,
          'SCRIPT_DIR="$SKILL_DIR/scripts"',
          'RUN_DIR="$SKILL_DIR/run"',
          'source "$SCRIPT_DIR/lib/compat.sh"',
          'source "$SCRIPT_DIR/lib/resolve-project.sh"',
          'source "$SCRIPT_DIR/lib/instance-id.sh"',
          'source "$SCRIPT_DIR/lib/node.sh"',
          'source "$SCRIPT_DIR/lib/hash.sh"',
          'source "$SCRIPT_DIR/lib/type-registry.sh"',
          'source "$SCRIPT_DIR/lib/storage.sh"',
          'source "$SCRIPT_DIR/lib/manifest.sh"',
          fnBody,
          `stop_codex_bridge ${bashQuote(project)}`,
        ].join("\n"),
      );
      const out = execFileSync(bash, ["-c", `source ${bashQuote(driverScript)}`], { encoding: "utf8", timeout: 20000, env });
      assert.strictEqual(out.trim(), "1", `stop_codex_bridge should report 1 killed, got: ${out}`);

      const deadline = Date.now() + 5000;
      let bridgeGone = false;
      while (Date.now() < deadline && !bridgeGone) {
        try { process.kill(bridgeChild.pid, 0); } catch (_) { bridgeGone = true; }
        if (!bridgeGone) sleepMs(200);
      }
      assert.ok(bridgeGone, "bridge process (native pid) must actually be dead after stop_codex_bridge — this is the regression a plain `kill \"$bpid\"` failed silently at");
      assert.ok(!fs.existsSync(pidfile), "bridge pidfile should be removed");

      bridgeChild = null;
    } finally {
      if (bridgeChild) {
        try { execFileSync("taskkill.exe", ["/PID", String(bridgeChild.pid), "/T", "/F"], { stdio: "ignore" }); } catch (_) {}
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  console.log(JSON.stringify({ ok: failures === 0, failures }));
}

function copyDirSync(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDirSync(s, d);
    else fs.copyFileSync(s, d);
  }
}

runAll().then(() => {
  const residual = residualWakerProcesses("agmsg-waker-lifecycle-test-");
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
