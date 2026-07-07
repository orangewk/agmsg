#!/usr/bin/env node
"use strict";

const assert = require("assert");
const childProcess = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..", "..");
const supervisor = path.join(repo, "scripts", "poc", "delivery-supervisor.js");
const adapter = path.join(repo, "scripts", "poc", "codex-idle-wake-adapter.js");
const runDir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-supervisor-codex-adapter-"));
const project = path.join(runDir, "project");
fs.mkdirSync(project, { recursive: true });
// Isolate the manifest.jsonl ledger (delivery-supervisor.js writes it via
// AGMSG_SKILL_DIR, see that script's skillRunDir()) into this same scratch
// dir — otherwise every run of this test appends real create/dispose lines
// into the repo's own (untracked, non-gitignored) run/manifest.jsonl.
const skillEnv = { ...process.env, AGMSG_SKILL_DIR: runDir };

function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function encodeFrame(payload) {
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  if (body.length < 126) return Buffer.concat([Buffer.from([0x81, body.length]), body]);
  const header = Buffer.alloc(4);
  header[0] = 0x81;
  header[1] = 126;
  header.writeUInt16BE(body.length, 2);
  return Buffer.concat([header, body]);
}

function decodeFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const first = buffer[offset];
    const second = buffer[offset + 1];
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let cursor = offset + 2;
    if (length === 126) { if (buffer.length - cursor < 2) break; length = buffer.readUInt16BE(cursor); cursor += 2; }
    if (length === 127) { if (buffer.length - cursor < 8) break; length = buffer.readUInt32BE(cursor + 4); cursor += 8; }
    let mask;
    if (masked) { if (buffer.length - cursor < 4) break; mask = buffer.slice(cursor, cursor + 4); cursor += 4; }
    if (buffer.length - cursor < length) break;
    let payload = buffer.slice(cursor, cursor + length);
    if (masked) payload = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
    frames.push({ opcode, text: payload.toString("utf8") });
    offset = cursor + length;
  }
  return { frames, rest: buffer.slice(offset) };
}

const seen = [];
let fakeServer;

function startFakeServer() {
  return new Promise((resolve) => {
    fakeServer = net.createServer((socket) => {
      let handshaken = false;
      let buffer = Buffer.alloc(0);
      socket.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        if (!handshaken) {
          const headerEnd = buffer.indexOf("\r\n\r\n");
          if (headerEnd === -1) return;
          const header = buffer.slice(0, headerEnd).toString("utf8");
          const key = header.split(/\r\n/).find((line) => /^Sec-WebSocket-Key:/i.test(line)).split(":")[1].trim();
          const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
          socket.write(["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", `Sec-WebSocket-Accept: ${accept}`, "", ""].join("\r\n"));
          buffer = buffer.slice(headerEnd + 4);
          handshaken = true;
        }
        const decoded = decodeFrames(buffer);
        buffer = decoded.rest;
        for (const frame of decoded.frames) {
          const msg = JSON.parse(frame.text);
          seen.push(msg);
          if (!Object.prototype.hasOwnProperty.call(msg, "id")) continue;
          let result = {};
          if (msg.method === "thread/loaded/list") result = { data: ["thread-fake-1"] };
          else if (msg.method === "thread/resume") result = { thread: { id: msg.params.threadId, status: { type: "idle" } } };
          else if (msg.method === "turn/start") result = { turn: { id: "turn-fake-1" } };
          socket.write(encodeFrame({ jsonrpc: "2.0", id: msg.id, result }));
        }
      });
    });
    fakeServer.listen(0, "127.0.0.1", () => resolve(fakeServer.address().port));
  });
}

function runCli(args) {
  return new Promise((resolve) => {
    const child = childProcess.spawn(process.execPath, [supervisor, ...args, "--run-dir", runDir, "--project", project], { cwd: repo, env: skillEnv });
    const stdout = [];
    const stderr = [];
    const timer = setTimeout(() => {
      child.kill();
      resolve({ status: null, stdout: Buffer.concat(stdout).toString("utf8"), stderr: Buffer.concat(stderr).toString("utf8"), error: new Error("timeout") });
    }, 5000);
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ status: code, stdout: Buffer.concat(stdout).toString("utf8"), stderr: Buffer.concat(stderr).toString("utf8") });
    });
  });
}

async function jsonRunAsync(args) {
  const result = await runCli(args);
  assert.strictEqual(result.status, 0, `${args.join(" ")} failed\nstdout=${result.stdout}\nstderr=${result.stderr}\nerror=${result.error && result.error.message}`);
  return JSON.parse(result.stdout);
}
function run(args) {
  return childProcess.spawnSync(process.execPath, [supervisor, ...args, "--run-dir", runDir, "--project", project], { cwd: repo, encoding: "utf8", env: skillEnv });
}

function jsonRun(args) {
  const result = run(args);
  assert.strictEqual(result.status, 0, `${args.join(" ")} failed\nstdout=${result.stdout}\nstderr=${result.stderr}`);
  return JSON.parse(result.stdout);
}

function waitForPort() {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const found = fs.readdirSync(runDir).find((name) => name.endsWith(".port"));
    if (found) return;
    sleep(50);
  }
  throw new Error("supervisor port not ready");
}

(async () => {
  const fakePort = await startFakeServer();
  const adapterCmd = `${JSON.stringify(process.execPath)} ${JSON.stringify(adapter)} --project ${JSON.stringify(project)} --app-server ws://127.0.0.1:${fakePort} --thread loaded`;
  const proc = childProcess.spawn(process.execPath, [supervisor, "start", "--run-dir", runDir, "--project", project, "--heartbeat-timeout-ms", "1000", "--poll-ms", "100", "--adapter-cmd", adapterCmd], { cwd: repo, stdio: ["ignore", "pipe", "pipe"], env: skillEnv });
  try {
    waitForPort();
    await jsonRunAsync(["attach", "--team", "mathdesk-desktop", "--name", "Eiji", "--session", "s1"]);
    await jsonRunAsync(["send", "--team", "mathdesk-desktop", "--from", "Anna", "--to", "Eiji", "--body", "supervisor to codex adapter"]);
    sleep(500);
    const methods = seen.map((msg) => msg.method).filter(Boolean);
    assert.deepStrictEqual(methods, ["initialize", "initialized", "thread/loaded/list", "thread/resume", "turn/start"]);
    const status = await jsonRunAsync(["status"]);
    assert.strictEqual(status.cursor, 1);
    const events = fs.readFileSync(status.files.eventLog, "utf8").trim().split(/\r?\n/).map((line) => JSON.parse(line));
    const adapterOk = events.find((event) => event.event === "adapter-ok");
    assert(adapterOk, "adapter-ok event was not recorded");
    assert.match(adapterOk.stdout, /"ok":true/);
    await jsonRunAsync(["stop"]);
    console.log(JSON.stringify({ ok: true, methods, adapterOk: true }, null, 2));
  } finally {
    if (!proc.killed) proc.kill();
    fakeServer.close();
  }
})().catch((error) => {
  if (fakeServer) fakeServer.close();
  console.error(error.stack || error.message);
  process.exit(1);
});

