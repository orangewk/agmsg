#!/usr/bin/env node
"use strict";

const crypto = require("crypto");
const net = require("net");
const path = require("path");

function usage() {
  console.log(`Usage: codex-idle-wake-adapter.js --project <path> --app-server ws://host:port [--thread <id|loaded|new>] [--request-timeout-ms <n>]

PoC one-shot adapter. Reads AGMSG_SUPERVISOR_MESSAGE_JSON and starts a Codex turn.
This is intentionally disposable and not wired into production delivery.`);
}

function parseArgs(argv) {
  const opts = { thread: "loaded", requestTimeoutMs: 10000 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") opts.help = true;
    else if (arg === "--project") opts.project = argv[++i];
    else if (arg === "--app-server") opts.appServer = argv[++i];
    else if (arg === "--thread") opts.thread = argv[++i];
    else if (arg === "--request-timeout-ms") opts.requestTimeoutMs = Number(argv[++i]);
    else if (arg === "--skip-resume") opts.skipResume = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return opts;
}

function parseWsTarget(url) {
  const match = /^ws:\/\/([^/:]+):(\d+)\/?$/.exec(url || "");
  if (!match) throw new Error(`--app-server must be ws://host:port, got ${url || "<empty>"}`);
  return { host: match[1], port: Number(match[2]) };
}

class WsJsonRpcClient {
  constructor(target, opts = {}) {
    this.target = target;
    this.requestTimeoutMs = opts.requestTimeoutMs || 0;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.handshakeBuffer = Buffer.alloc(0);
    this.handshakeComplete = false;
    this.connected = false;
    this.socket = null;
  }

  start() {
    return new Promise((resolve, reject) => {
      const key = crypto.randomBytes(16).toString("base64");
      this.expectedAccept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
      this.socket = net.createConnection(this.target);
      this.socket.on("connect", () => {
        this.socket.write([
          "GET / HTTP/1.1",
          "Host: localhost",
          "Upgrade: websocket",
          "Connection: Upgrade",
          `Sec-WebSocket-Key: ${key}`,
          "Sec-WebSocket-Version: 13",
          "",
          "",
        ].join("\r\n"));
      });
      this.socket.on("data", (chunk) => this.handleData(chunk, resolve, reject));
      this.socket.on("error", reject);
      this.socket.on("close", () => this.rejectAll(new Error("app-server connection closed")));
    });
  }

  handleData(chunk, resolveStart, rejectStart) {
    if (!this.handshakeComplete) {
      this.handshakeBuffer = Buffer.concat([this.handshakeBuffer, chunk]);
      const headerEnd = this.handshakeBuffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = this.handshakeBuffer.slice(0, headerEnd).toString("utf8");
      const rest = this.handshakeBuffer.slice(headerEnd + 4);
      const lines = header.split(/\r\n/);
      const headers = new Map();
      for (const line of lines.slice(1)) {
        const index = line.indexOf(":");
        if (index !== -1) headers.set(line.slice(0, index).toLowerCase(), line.slice(index + 1).trim());
      }
      if (!/^HTTP\/1\.1 101\b/.test(lines[0] || "") || headers.get("sec-websocket-accept") !== this.expectedAccept) {
        rejectStart(new Error("websocket upgrade failed"));
        this.stop();
        return;
      }
      this.handshakeComplete = true;
      this.connected = true;
      resolveStart();
      if (rest.length) this.handleWebSocketBytes(rest);
      return;
    }
    this.handleWebSocketBytes(chunk);
  }

  handleWebSocketBytes(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < offset + 2) return;
        length = this.buffer.readUInt16BE(offset);
        offset += 2;
      } else if (length === 127) {
        if (this.buffer.length < offset + 8) return;
        const high = this.buffer.readUInt32BE(offset);
        const low = this.buffer.readUInt32BE(offset + 4);
        if (high !== 0) throw new Error("websocket frame too large");
        length = low;
        offset += 8;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (this.buffer.length < offset + length) return;
      let payload = this.buffer.slice(offset, offset + length);
      if (masked) {
        const mask = this.buffer.slice(maskOffset, maskOffset + 4);
        payload = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
      }
      this.buffer = this.buffer.slice(offset + length);
      if (opcode === 0x1) this.handleLine(payload.toString("utf8"));
      if (opcode === 0x8) this.stop();
    }
  }

  handleLine(line) {
    if (!line.trim()) return;
    const message = JSON.parse(line);
    if (!Object.prototype.hasOwnProperty.call(message, "id")) return;
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    if (message.error) pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
    else pending.resolve(message.result);
  }

  request(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      let timer = null;
      if (this.requestTimeoutMs > 0) {
        timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new Error(`${method} timed out after ${this.requestTimeoutMs}ms`));
        }, this.requestTimeoutMs);
      }
      this.pending.set(id, {
        resolve: (value) => { if (timer) clearTimeout(timer); resolve(value); },
        reject: (error) => { if (timer) clearTimeout(timer); reject(error); },
      });
      this.sendJson({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method, params = {}) {
    this.sendJson({ jsonrpc: "2.0", method, params });
  }

  sendJson(value) {
    if (!this.connected) throw new Error("websocket not connected");
    this.sendFrame(0x1, Buffer.from(JSON.stringify(value), "utf8"));
  }

  sendFrame(opcode, payload) {
    const length = payload.length;
    let headerLength = 2;
    if (length >= 126 && length <= 0xffff) headerLength += 2;
    if (length > 0xffff) headerLength += 8;
    const mask = crypto.randomBytes(4);
    const frame = Buffer.alloc(headerLength + 4 + length);
    frame[0] = 0x80 | opcode;
    if (length < 126) frame[1] = 0x80 | length;
    else if (length <= 0xffff) { frame[1] = 0x80 | 126; frame.writeUInt16BE(length, 2); }
    else { frame[1] = 0x80 | 127; frame.writeUInt32BE(0, 2); frame.writeUInt32BE(length, 6); }
    mask.copy(frame, headerLength);
    for (let i = 0; i < length; i += 1) frame[headerLength + 4 + i] = payload[i] ^ mask[i % 4];
    this.socket.write(frame);
  }

  rejectAll(error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  stop() {
    this.connected = false;
    if (this.socket && !this.socket.destroyed) this.socket.destroy();
  }
}

function buildPrompt(message) {
  const body = message.body || "";
  return [
    "[$agmsg] Incoming message delivered by delivery-supervisor PoC.",
    `From: ${message.from || "unknown"}`,
    `To: ${message.to || "unknown"}`,
    `Team: ${message.team || "unknown"}`,
    "",
    body,
  ].join("\n");
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { usage(); return; }
  if (!opts.project) throw new Error("missing --project");
  if (!opts.appServer) throw new Error("missing --app-server");
  const message = JSON.parse(process.env.AGMSG_SUPERVISOR_MESSAGE_JSON || "{}");
  if (!message.to) throw new Error("AGMSG_SUPERVISOR_MESSAGE_JSON is missing to");

  const client = new WsJsonRpcClient(parseWsTarget(opts.appServer), { requestTimeoutMs: opts.requestTimeoutMs });
  await client.start();
  await client.request("initialize", {
    clientInfo: { name: "agmsg-supervisor-poc", title: "agmsg Supervisor PoC", version: "poc" },
    capabilities: { experimentalApi: true, requestAttestation: false, optOutNotificationMethods: [] },
  });
  client.notify("initialized");

  let threadId = opts.thread;
  if (threadId === "new") {
    const started = await client.request("thread/start", {
      cwd: path.resolve(opts.project),
      runtimeWorkspaceRoots: [path.resolve(opts.project)],
      ephemeral: false,
    });
    threadId = started.thread && started.thread.id;
    if (!threadId) throw new Error("thread/start did not return a thread id");
  } else if (threadId === "loaded") {
    const loaded = await client.request("thread/loaded/list", {});
    const ids = loaded && Array.isArray(loaded.data) ? loaded.data : [];
    if (ids.length !== 1) throw new Error(`expected exactly one loaded thread, got ${ids.length}`);
    threadId = ids[0];
  }

  if (!opts.skipResume) {
    const resumed = await client.request("thread/resume", {
    threadId,
    cwd: path.resolve(opts.project),
    runtimeWorkspaceRoots: [path.resolve(opts.project)],
    excludeTurns: true,
  });
    if (!resumed.thread || resumed.thread.id !== threadId) throw new Error("thread/resume did not return the requested thread");
    const statusType = resumed.thread.status && resumed.thread.status.type;
    if (statusType === "active") throw new Error("thread is active; idle-wake test requires an idle thread");
  }

  await client.request("turn/start", {
    threadId,
    input: [{ type: "text", text: buildPrompt(message), text_elements: [] }],
    cwd: path.resolve(opts.project),
    runtimeWorkspaceRoots: [path.resolve(opts.project)],
  });
  client.stop();
  console.log(JSON.stringify({ ok: true, threadId }));
}

main().catch((error) => {
  console.error(`codex-idle-wake-adapter: ${error.message}`);
  process.exit(1);
});


