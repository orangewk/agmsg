#!/usr/bin/env node
"use strict";

const assert = require("assert");
const childProcess = require("child_process");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..", "..");
const script = path.join(repo, "scripts", "poc", "delivery-supervisor.js");
const runDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-supervisor-poc-"));
const project = path.join(runDir, "project");
fs.mkdirSync(project, { recursive: true });
// Isolate the manifest.jsonl ledger (delivery-supervisor.js writes it via
// AGMSG_SKILL_DIR, see that script's skillRunDir()) into this same scratch
// dir — otherwise every run of this test appends real create/dispose lines
// into the repo's own (untracked, non-gitignored) run/manifest.jsonl.
const skillEnv = { ...process.env, AGMSG_SKILL_DIR: runDir };

function run(args, opts = {}) {
  return childProcess.spawnSync(process.execPath, [script, ...args, "--run-dir", runDir, "--project", project], {
    cwd: repo,
    encoding: "utf8",
    env: skillEnv,
    ...opts,
  });
}

function start() {
  const proc = childProcess.spawn(process.execPath, [script, "start", "--run-dir", runDir, "--project", project, "--heartbeat-timeout-ms", "700", "--poll-ms", "100"], {
    cwd: repo,
    stdio: ["ignore", "pipe", "pipe"],
    env: skillEnv,
  });
  return proc;
}

function waitForPort() {
  const deadline = Date.now() + 5000;
  const file = fs.readdirSync(runDir).find((name) => name.endsWith(".port"));
  if (file) return Number(fs.readFileSync(path.join(runDir, file), "utf8"));
  while (Date.now() < deadline) {
    const found = fs.readdirSync(runDir).find((name) => name.endsWith(".port"));
    if (found) return Number(fs.readFileSync(path.join(runDir, found), "utf8"));
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
  }
  throw new Error("port file not created");
}

function jsonRun(args) {
  const result = run(args);
  assert.strictEqual(result.status, 0, `${args.join(" ")} failed\nstdout=${result.stdout}\nstderr=${result.stderr}`);
  return JSON.parse(result.stdout);
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function adapterLines() {
  const file = fs.readdirSync(runDir).find((name) => name.endsWith(".adapter.log"));
  if (!file) return [];
  return fs.readFileSync(path.join(runDir, file), "utf8").split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

let proc;
try {
  proc = start();
  waitForPort();

  const second = run(["start", "--heartbeat-timeout-ms", "700", "--poll-ms", "100"]);
  assert.notStrictEqual(second.status, 0, "second supervisor start should be rejected");
  assert.match(second.stderr, /already running/, "second start should report singleton lock/port");

  jsonRun(["attach", "--team", "mathdesk-desktop", "--name", "Eiji", "--session", "s1"]);
  jsonRun(["send", "--team", "mathdesk-desktop", "--from", "Anna", "--to", "Eiji", "--body", "first"]);
  sleep(250);
  let lines = adapterLines();
  assert.strictEqual(lines.length, 1, "first message should deliver once");
  assert.strictEqual(lines[0].session, "s1");

  sleep(250);
  lines = adapterLines();
  assert.strictEqual(lines.length, 1, "cursor should prevent duplicate delivery");

  jsonRun(["heartbeat", "--team", "mathdesk-desktop", "--name", "Eiji", "--session", "s1"]);
  let status = jsonRun(["status"]);
  assert.strictEqual(status.sessions[0].status, "live", "quiet live session should remain live after heartbeat");

  sleep(900);
  status = jsonRun(["status"]);
  assert.strictEqual(status.sessions[0].status, "stale", "dead session should become stale after timeout");

  jsonRun(["send", "--team", "mathdesk-desktop", "--from", "Anna", "--to", "Eiji", "--body", "held"]);
  sleep(250);
  lines = adapterLines();
  assert.strictEqual(lines.length, 1, "message to stale session should be held");

  jsonRun(["attach", "--team", "mathdesk-desktop", "--name", "Eiji", "--session", "s2"]);
  sleep(250);
  lines = adapterLines();
  assert.strictEqual(lines.length, 2, "held message should deliver after reattach");
  assert.strictEqual(lines[1].session, "s2", "reattached session should receive held message");

  const pid = proc.pid;
  status = jsonRun(["status"]);
  assert.strictEqual(status.pid, pid, "supervisor process should survive session stale/reattach sequence");

  jsonRun(["stop"]);
  proc = null;
  console.log(JSON.stringify({ ok: true, runDir }, null, 2));
} finally {
  if (proc && !proc.killed) proc.kill();
}
