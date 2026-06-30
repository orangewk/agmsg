#!/usr/bin/env node
"use strict";

const childProcess = require("child_process");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..", "..");
const owner = path.join(repo, "scripts", "poc", "codex-app-server-owner.js");
const adapter = path.join(repo, "scripts", "poc", "codex-idle-wake-adapter.js");
const project = process.argv[2] || process.cwd();
const runDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-remote-wake-"));

function nativeCodexExe() {
  return path.join(os.homedir(), "AppData", "Roaming", "npm", "node_modules", "@openai", "codex", "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe");
}

function runNode(args, opts = {}) {
  return childProcess.spawnSync(process.execPath, args, { cwd: repo, encoding: "utf8", ...opts });
}

function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function waitForLoaded(endpoint, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const env = { ...process.env, AGMSG_SUPERVISOR_MESSAGE_JSON: JSON.stringify({ id: 1, team: "poc", from: "probe", to: "remote", body: "probe" }) };
    const r = runNode([adapter, "--project", project, "--app-server", endpoint, "--thread", "loaded", "--request-timeout-ms", "3000"], { env, timeout: 5000 });
    const output = `${r.stdout || ""}${r.stderr || ""}`;
    if (r.status === 0) return { ok: true, output };
    if (!/expected exactly one loaded thread, got 0|no loaded|ECONNRESET|timed out/i.test(output)) {
      return { ok: false, output, status: r.status };
    }
    sleep(500);
  }
  return { ok: false, output: "timeout waiting for loaded remote thread" };
}

function taskkill(pid) {
  if (!pid) return;
  if (process.platform === "win32") childProcess.spawnSync("taskkill.exe", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
  else { try { process.kill(pid); } catch (_) {} }
}

const result = { ok: false, runDir, project };
let remote;
try {
  const start = runNode([owner, "start", "--run-dir", runDir]);
  result.ownerStart = { status: start.status, stdout: start.stdout, stderr: start.stderr };
  if (start.status !== 0) throw new Error("owner start failed");
  const startJson = JSON.parse(start.stdout);
  result.endpoint = startJson.endpoint;
  result.ownerPid = startJson.pid;

  const codex = nativeCodexExe();
  const remoteLog = path.join(runDir, "remote-cli.log");
  const out = fs.openSync(remoteLog, "a");
  remote = childProcess.spawn(codex, ["--remote", startJson.endpoint, "--cd", project, "--no-alt-screen"], {
    cwd: project,
    stdio: ["ignore", out, out],
    windowsHide: true,
  });
  result.remotePid = remote.pid;
  result.remoteLog = remoteLog;

  sleep(3000);
  const wake = waitForLoaded(startJson.endpoint, 20000);
  result.wake = wake;
  result.remoteLogTail = fs.existsSync(remoteLog) ? fs.readFileSync(remoteLog, "utf8").slice(-4000) : "";
  result.ok = Boolean(wake.ok);
} catch (error) {
  result.error = error.message;
} finally {
  if (remote && remote.pid) taskkill(remote.pid);
  runNode([owner, "stop", "--run-dir", runDir]);
}

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
