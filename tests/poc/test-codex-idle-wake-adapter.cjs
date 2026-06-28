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
const adapter = path.join(repo, "scripts", "poc", "codex-idle-wake-adapter.js");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-codex-adapter-poc-"));
const project = path.join(tmp, "project");
fs.mkdirSync(project, { recursive: true });

function encodeFrame(payload) {
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  let header;
  if (body.length < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x81;
    header[1] = body.length;
  } else if (body.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(body.length, 6);
  }
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
    if (length === 126) {
      if (buffer.length - cursor < 2) break;
      length = buffer.readUInt16BE(cursor);
      cursor += 2;
    } else if (length === 127) {
      if (buffer.length - cursor < 8) break;
      const high = buffer.readUInt32BE(cursor);
      const low = buffer.readUInt32BE(cursor + 4);
      assert.strictEqual(high, 0);
      length = low;
      cursor += 8;
    }
    let mask;
    if (masked) {
      if (buffer.length - cursor < 4) break;
      mask = buffer.slice(cursor, cursor + 4);
      cursor += 4;
    }
    if (buffer.length - cursor < length) break;
    let payload = buffer.slice(cursor, cursor + length);
    if (masked) payload = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
    frames.push({ opcode, text: payload.toString("utf8"), end: cursor + length });
    offset = cursor + length;
  }
  return { frames, rest: buffer.slice(offset) };
}

const seen = [];
let server;

function runAdapter(args, env) {
  return new Promise((resolve) => {
    const child = childProcess.spawn(process.execPath, args, { cwd: repo, env });
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
function startServer() {
  return new Promise((resolve) => {
    server = net.createServer((socket) => {
      let handshaken = false;
      let buffer = Buffer.alloc(0);
      socket.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        if (!handshaken) {
          const headerEnd = buffer.indexOf("\r\n\r\n");
          if (headerEnd === -1) return;
          const header = buffer.slice(0, headerEnd).toString("utf8");
          const keyLine = header.split(/\r\n/).find((line) => /^Sec-WebSocket-Key:/i.test(line));
          const key = keyLine.split(":")[1].trim();
          const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
          socket.write([
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            `Sec-WebSocket-Accept: ${accept}`,
            "",
            "",
          ].join("\r\n"));
          buffer = buffer.slice(headerEnd + 4);
          handshaken = true;
        }
        const decoded = decodeFrames(buffer);
        buffer = decoded.rest;
        for (const frame of decoded.frames) {
          if (frame.opcode !== 1) continue;
          const msg = JSON.parse(frame.text);
          seen.push(msg);
          if (!Object.prototype.hasOwnProperty.call(msg, "id")) continue;
          let result = {};
          if (msg.method === "initialize") result = {};
          else if (msg.method === "thread/loaded/list") result = { data: ["thread-fake-1"] };
          else if (msg.method === "thread/resume") result = { thread: { id: msg.params.threadId, status: { type: "idle" } } };
          else if (msg.method === "turn/start") result = { turn: { id: "turn-fake-1" } };
          socket.write(encodeFrame({ jsonrpc: "2.0", id: msg.id, result }));
        }
      });
    });
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

(async () => {
  const port = await startServer();
  const env = {
    ...process.env,
    AGMSG_SUPERVISOR_MESSAGE_JSON: JSON.stringify({ id: 7, team: "mathdesk-desktop", from: "Anna", to: "Eiji", body: "wake please" }),
  };
  const result = await runAdapter([adapter, "--project", project, "--app-server", `ws://127.0.0.1:${port}`, "--thread", "loaded"], env);
  server.close();
  assert.strictEqual(result.status, 0, `adapter failed\nseen=${JSON.stringify(seen)}\nstdout=${result.stdout}\nstderr=${result.stderr}\nerror=${result.error && result.error.message}`);
  const methods = seen.map((msg) => msg.method).filter(Boolean);
  assert.deepStrictEqual(methods, ["initialize", "initialized", "thread/loaded/list", "thread/resume", "turn/start"]);
  const turnStart = seen.find((msg) => msg.method === "turn/start");
  assert.strictEqual(turnStart.params.threadId, "thread-fake-1");
  assert.match(turnStart.params.input[0].text, /wake please/);
  assert.match(turnStart.params.input[0].text, /From: Anna/);
  console.log(JSON.stringify({ ok: true, methods }, null, 2));
})().catch((error) => {
  if (server) server.close();
  console.error(error.stack || error.message);
  process.exit(1);
});





