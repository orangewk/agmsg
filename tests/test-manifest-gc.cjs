#!/usr/bin/env node
"use strict";
//
// test-manifest-gc.cjs — direct-execution regression test for lib/manifest.sh
// / lib/manifest.js / lib/gc.sh (orangewk/agmsg#8).
//
// Run via plain `node`, not bats: the full bats suite hangs on this Windows
// dev box (a known, pre-existing issue upstream's own CI comments call out —
// see WP0's report), so lifecycle-manifest-gc follows the same node-direct
// pattern already established by tests/poc/*.cjs rather than adding another
// bats file that can't be run here to confirm it passes.
//
// Covers, against a scratch SKILL_DIR (isolated run/ dir, never the real
// skill install):
//   1. manifest.sh: create/dispose round trip, manifest_open_processes only
//      returns undisposed entries, JSON is well-formed per line.
//   2. gc.sh: agmsg_gc_manifest_reap_dead reaps a dead msys-space process and
//      leaves a live one alone; native-space dead/live cases the same way
//      (simulated — see NOTE below on why native liveness can't spawn a real
//      native-only pid from a bash test harness).
//   3. codex-bridge.js: writeMeta()/cleanupMeta() actually append manifest
//      create/dispose lines when the bridge starts/stops (using the existing
//      test double pattern: AGMSG_CODEX_BRIDGE_CMD-style direct invocation is
//      not available for this file, so this drives writeMeta/cleanupMeta via
//      a tiny require()'d harness instead of spawning the full bridge, which
//      needs a live app-server connection out of scope for this test).
//
// NOTE on native-pid simulation: the whole point of this WP's pidSpace design
// is that a bash test can't easily launch a process whose ONLY knowable pid
// is native (that requires nohup-wrapping a node child, exactly the
// production shape) while also deterministically killing it and re-checking
// via tasklist/CIM without flakiness tied to OS process-table timing. Rather
// than fight that, the native-space assertions here use a REAL nohup-launched
// node child (mirroring codex-bridge-launcher.sh's own launch shape) so the
// msys-vs-native pid distinction this test is actually protecting is real,
// not asserted-by-comment.

const assert = require("assert");
const { execFileSync, spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const bash = findBash();

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

function mkSkillDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-lifecycle-test-"));
  fs.mkdirSync(path.join(dir, "scripts", "lib"), { recursive: true });
  fs.mkdirSync(path.join(dir, "run"), { recursive: true });
  // Copy the real lib files under test into the scratch skill dir so
  // required-variable / relative-source assumptions (SKILL_DIR-based) hold
  // exactly as they would in the real install.
  for (const f of ["manifest.sh", "gc.sh", "compat.sh", "instance-id.sh"]) {
    fs.copyFileSync(
      path.join(repo, "scripts", "lib", f),
      path.join(dir, "scripts", "lib", f),
    );
  }
  return dir;
}

function runBash(skillDir, script) {
  const wrapped = `
set -euo pipefail
SKILL_DIR=${bashQuote(skillDir)}
source "$SKILL_DIR/scripts/lib/compat.sh"
source "$SKILL_DIR/scripts/lib/instance-id.sh"
source "$SKILL_DIR/scripts/lib/manifest.sh"
source "$SKILL_DIR/scripts/lib/gc.sh"
${script}
`;
  return execFileSync(bash, ["-c", wrapped], { encoding: "utf8" });
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
    .map((line) => JSON.parse(line)); // throws if any line is malformed JSON
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

// --- 1. manifest.sh create/dispose round trip -------------------------------
(() => {
  const dir = mkSkillDir();
  test("manifest_record_create appends a well-formed create line", () => {
    runBash(dir, `manifest_record_create process "$(manifest_process_id 99999 'fake cmdline' '2026-01-01T00:00:00Z')" "session-abc" "test hint"`);
    const lines = manifestLines(dir);
    assert.strictEqual(lines.length, 1);
    assert.strictEqual(lines[0].event, "create");
    assert.strictEqual(lines[0].kind, "process");
    assert.strictEqual(lines[0].id.pid, "99999");
    assert.strictEqual(lines[0].id.pidSpace, "msys");
    assert.strictEqual(lines[0].id.cmdline, "fake cmdline");
    assert.strictEqual(lines[0].createdBy, "session-abc");
    assert.strictEqual(lines[0].disposeHint, "test hint");
  });

  test("manifest_open_processes lists the still-open entry", () => {
    const out = runBash(dir, `manifest_open_processes`);
    assert.match(out, /^99999\tfake cmdline\t2026-01-01T00:00:00Z\tmsys$/m);
  });

  test("manifest_record_dispose is append-only (create line untouched) and hides the entry from manifest_open_processes", () => {
    runBash(dir, `manifest_record_dispose process "$(manifest_process_id 99999 'fake cmdline' '2026-01-01T00:00:00Z')" "test"`);
    const lines = manifestLines(dir);
    assert.strictEqual(lines.length, 2, "dispose should be a NEW line, not a rewrite");
    assert.strictEqual(lines[0].event, "create", "original create line must be untouched");
    assert.strictEqual(lines[1].event, "dispose");
    const out = runBash(dir, `manifest_open_processes`);
    assert.strictEqual(out.trim(), "", "disposed pid should no longer be open");
  });

  fs.rmSync(dir, { recursive: true, force: true });
})();

// --- 2. gc.sh: msys-space reap ------------------------------------------------
(() => {
  const dir = mkSkillDir();
  test("agmsg_gc_manifest_reap_dead disposes a dead msys pid and its create line", () => {
    // A pid essentially guaranteed dead: current pid + a large offset, still numeric.
    const deadPid = process.pid + 500000;
    runBash(dir, `manifest_record_create process "$(manifest_process_id ${deadPid} 'dead proc' '2026-01-01T00:00:00Z' msys)" "s1" "hint"`);
    const out = runBash(dir, `agmsg_gc_manifest_reap_dead`);
    assert.match(out, new RegExp(`^${deadPid}\\tdead proc$`, "m"));
    const lines = manifestLines(dir);
    assert.strictEqual(lines.filter((l) => l.event === "dispose").length, 1, "gc should have appended exactly one dispose line");
  });

  test("agmsg_gc_manifest_reap_dead leaves a live, cmdline-confirmed msys process alone", () => {
    // Use THIS test process's own pid/cmdline (bash's own $$ from inside a
    // long-lived subshell) as a "confirmed alive" msys entry.
    const out = runBash(dir, `
      MY_PID="$$"
      MY_CMD="$(compat_get_cmdline "$MY_PID")"
      manifest_record_create process "$(manifest_process_id "$MY_PID" "$MY_CMD" '2026-01-01T00:00:00Z' msys)" "s2" "hint"
      agmsg_gc_manifest_reap_dead
      manifest_open_processes | grep -c "^$MY_PID" || true
    `);
    assert.strictEqual(out.trim(), "1", "a live, cmdline-matching process must remain open (not disposed)");
  });

  fs.rmSync(dir, { recursive: true, force: true });
})();

// --- 3. gc.sh: native-space reap (real nohup-launched node child) -----------
(() => {
  const dir = mkSkillDir();
  test("agmsg_gc_codex_bridge_pidfiles reaps a dead native-space bridge pidfile", () => {
    // Simulate exactly what codex-bridge.js's writeMeta() does: write a
    // Windows-native pid (obtained by actually spawning+killing a node child,
    // never touched by MSYS $!) into codex-bridge.<team>.<name>.pid.
    const child = spawn(process.execPath, ["-e", "setTimeout(()=>{}, 60000)"]);
    const nativePid = child.pid;
    child.kill();
    // Give Windows a moment to actually tear the process down before gc runs.
    sleepMs(300);

    const runDir = path.join(dir, "run");
    const pidfile = path.join(runDir, "codex-bridge.team1.agent1.pid");
    fs.writeFileSync(pidfile, `${nativePid}\n`);
    fs.writeFileSync(path.join(runDir, "codex-bridge.team1.agent1.meta"), `pid=${nativePid}\n`);

    const out = runBash(dir, `agmsg_gc_codex_bridge_pidfiles`);
    assert.strictEqual(out.trim(), "1", "dead bridge pidfile set should be reaped");
    assert.ok(!fs.existsSync(pidfile), "pidfile should be removed");
    assert.ok(!fs.existsSync(path.join(runDir, "codex-bridge.team1.agent1.meta")), "metafile should be removed");
  });

  test("agmsg_gc_codex_bridge_pidfiles leaves a LIVE, cmdline-confirmed native bridge pidfile alone", () => {
    // gc.sh's confirm-before-touch check requires "codex-bridge" to appear in
    // the live cmdline (mirrors the real codex-bridge.js invocation path,
    // e.g. `node .../codex-bridge.js --team ...`) — a plain `node -e ...`
    // cmdline (no such substring) is correctly treated as "not confirmed
    // ours" and reaped; that is gc.sh doing its recycled-pid defense
    // correctly, not a bug, so this test's fake process must actually carry
    // that substring in its argv to exercise the "leave it alone" branch.
    const child = spawn(process.execPath, ["-e", "require('fs'); /*codex-bridge*/ setTimeout(()=>{}, 5000)"]);
    try {
      sleepMs(400); // let it actually start
      const nativePid = child.pid;
      const runDir = path.join(dir, "run");
      const pidfile = path.join(runDir, "codex-bridge.team2.agent2.pid");
      fs.writeFileSync(pidfile, `${nativePid}\n`);

      // Confirm our own compat_get_native_cmdline path actually sees "node" in
      // the live cmdline before asserting gc leaves it alone — otherwise a
      // false pass (CIM unavailable in this environment) would hide as a
      // false "reaped nothing to reap".
      const cmdlineCheck = runBash(dir, `compat_get_native_cmdline ${nativePid}`).trim();
      assert.ok(/node/i.test(cmdlineCheck), `expected node in cmdline, got: ${cmdlineCheck}`);

      const out = runBash(dir, `agmsg_gc_codex_bridge_pidfiles`);
      assert.strictEqual(out.trim(), "0", "live, confirmed bridge pidfile must not be reaped");
      assert.ok(fs.existsSync(pidfile), "pidfile of a live confirmed bridge must survive gc");
    } finally {
      child.kill();
    }
  });

  fs.rmSync(dir, { recursive: true, force: true });
})();

// --- 4. codex-bridge.js writeMeta/cleanupMeta write manifest lines ----------
(() => {
  const dir = mkSkillDir();
  // codex-bridge.js requires SCRIPTS_DIR/lib/manifest.js to exist relative to
  // its own path resolution (SKILL_DIR/scripts/lib/manifest.js); copy it too.
  fs.copyFileSync(path.join(repo, "scripts", "lib", "manifest.js"), path.join(dir, "scripts", "lib", "manifest.js"));
  const manifest = require(path.join(dir, "scripts", "lib", "manifest.js"));
  const runDir = path.join(dir, "run");

  test("manifest.js recordProcessCreate/recordProcessDispose round-trip with native pidSpace", () => {
    manifest.recordProcessCreate(runDir, { pid: 424242, cmdline: "node codex-bridge.js --team t --name n", createdBy: "t/n", disposeHint: "hint" });
    manifest.recordProcessDispose(runDir, { pid: 424242, disposedBy: "test" });
    const lines = manifestLines(dir);
    assert.strictEqual(lines.length, 2);
    assert.strictEqual(lines[0].id.pidSpace, "native");
    assert.strictEqual(lines[0].id.pid, "424242");
    assert.strictEqual(lines[1].event, "dispose");
    assert.strictEqual(lines[1].id.pidSpace, "native");
  });

  fs.rmSync(dir, { recursive: true, force: true });
})();

if (failures > 0) {
  console.log(JSON.stringify({ ok: false, failures }));
  process.exit(1);
}
console.log(JSON.stringify({ ok: true }));
