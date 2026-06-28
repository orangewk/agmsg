#!/usr/bin/env node
"use strict";

const assert = require("assert");
const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..", "..");
const script = path.join(repo, "scripts", "poc", "delivery-supervisor.js");
const runDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-supervisor-adapter-poc-"));
const project = path.join(runDir, "project");
fs.mkdirSync(project, { recursive: true });

function run(args) {
  return childProcess.spawnSync(process.execPath, [script, ...args, "--run-dir", runDir, "--project", project], {
    cwd: repo,
    encoding: "utf8",
  });
}

function start() {
  return childProcess.spawn(process.execPath, [
    script, "start",
    "--run-dir", runDir,
    "--project", project,
    "--heartbeat-timeout-ms", "700",
    "--poll-ms", "100",
    "--adapter-cmd", `${JSON.stringify(process.execPath)} -e "process.exit(3)"`,
  ], { cwd: repo, stdio: ["ignore", "pipe", "pipe"] });
}

function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function waitForPort() {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const found = fs.readdirSync(runDir).find((name) => name.endsWith(".port"));
    if (found) return;
    sleep(50);
  }
  throw new Error("port file not created");
}

function jsonRun(args) {
  const result = run(args);
  assert.strictEqual(result.status, 0, `${args.join(" ")} failed\nstdout=${result.stdout}\nstderr=${result.stderr}`);
  return JSON.parse(result.stdout);
}

function eventLines() {
  const file = fs.readdirSync(runDir).find((name) => name.endsWith(".events.log"));
  if (!file) return [];
  return fs.readFileSync(path.join(runDir, file), "utf8").split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

let proc;
try {
  proc = start();
  waitForPort();
  jsonRun(["attach", "--team", "mathdesk-desktop", "--name", "Eiji", "--session", "s1"]);
  jsonRun(["send", "--team", "mathdesk-desktop", "--from", "Anna", "--to", "Eiji", "--body", "adapter-fails"]);
  sleep(250);
  const status = jsonRun(["status"]);
  assert.strictEqual(status.cursor, 0, "adapter failure must not advance cursor");
  assert(eventLines().some((entry) => entry.event === "adapter-fail"), "adapter failure should be attributed separately");
  jsonRun(["stop"]);
  proc = null;
  console.log(JSON.stringify({ ok: true, runDir }, null, 2));
} finally {
  if (proc && !proc.killed) proc.kill();
}
