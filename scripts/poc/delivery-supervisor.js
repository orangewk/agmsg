#!/usr/bin/env node
"use strict";

const fs = require("fs");
const childProcess = require("child_process");
const http = require("http");
const os = require("os");
const path = require("path");

const DEFAULT_HEARTBEAT_TIMEOUT_MS = 3000;
const DEFAULT_POLL_MS = 250;

function usage() {
  console.log(`Usage: delivery-supervisor.js <command> [options]

PoC delivery supervisor. This is intentionally disposable and is not wired into
production delivery.sh.

Commands:
  start       Start a project singleton supervisor.
  attach      Register/refresh a session heartbeat.
  heartbeat   Refresh a session heartbeat.
  send        Append a message to the supervisor mailbox.
  status      Print supervisor status JSON.
  stop        Stop the supervisor.

Common options:
  --run-dir <path>     Runtime directory (default: <repo>/run/poc-delivery-supervisor)
  --project <path>     Project key (default: cwd)

start options:
  --heartbeat-timeout-ms <n>  Stale timeout (default: ${DEFAULT_HEARTBEAT_TIMEOUT_MS})
  --poll-ms <n>               Poll interval (default: ${DEFAULT_POLL_MS})
  --adapter-log <path>        File receiving mock deliveries
  --adapter-cmd <command>     Optional command run for each delivery

attach/heartbeat options:
  --team <team> --name <agent> --session <id>

send options:
  --team <team> --from <agent> --to <agent> --body <text>
`);
}

function parseArgs(argv) {
  const command = argv[0] && !argv[0].startsWith("--") ? argv[0] : "";
  const opts = { command };
  const startIndex = command ? 1 : 0;
  for (let i = startIndex; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") opts.help = true;
    else if (arg.startsWith("--")) {
      const key = arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        opts[key] = true;
      } else {
        opts[key] = next;
        i += 1;
      }
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return opts;
}

function repoRoot() {
  return path.resolve(__dirname, "..", "..");
}

function projectHash(project) {
  let h = 2166136261;
  for (const ch of String(project)) {
    h ^= ch.charCodeAt(0);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

function paths(opts) {
  const project = path.resolve(opts.project || process.cwd());
  const runDir = path.resolve(opts.runDir || path.join(repoRoot(), "run", "poc-delivery-supervisor"));
  const key = projectHash(project);
  return {
    project,
    runDir,
    key,
    portFile: path.join(runDir, `supervisor.${key}.port`),
    lockFile: path.join(runDir, `supervisor.${key}.lock`),
    mailboxFile: path.join(runDir, `supervisor.${key}.mailbox.jsonl`),
    stateFile: path.join(runDir, `supervisor.${key}.state.json`),
    eventLog: path.join(runDir, `supervisor.${key}.events.log`),
    adapterLog: path.resolve(opts.adapterLog || path.join(runDir, `supervisor.${key}.adapter.log`)),
  };
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (_) {
    return fallback;
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
}

function appendLine(file, line) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(file, `${line}${os.EOL}`);
}

function appendEvent(p, event, fields = {}) {
  appendLine(p.eventLog, JSON.stringify({ ts: new Date().toISOString(), event, ...fields }));
}

function readMailbox(file) {
  try {
    return fs.readFileSync(file, "utf8")
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch (_) {
    return [];
  }
}

function request(port, method, pathname, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? Buffer.from(JSON.stringify(body)) : Buffer.alloc(0);
    const req = http.request({ host: "127.0.0.1", port, path: pathname, method, headers: {
      "content-type": "application/json",
      "content-length": payload.length,
    }}, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(text || `HTTP ${res.statusCode}`));
          return;
        }
        try { resolve(text ? JSON.parse(text) : {}); }
        catch (_) { resolve({ text }); }
      });
    });
    req.on("error", reject);
    req.end(payload);
  });
}

function readPort(p) {
  const port = Number(fs.readFileSync(p.portFile, "utf8").trim());
  if (!Number.isInteger(port) || port <= 0) throw new Error(`invalid port file: ${p.portFile}`);
  return port;
}

async function probeExisting(p) {
  try {
    const port = readPort(p);
    await request(port, "GET", "/status");
    return port;
  } catch (_) {
    return 0;
  }
}

function requireFields(opts, names) {
  for (const name of names) {
    if (!opts[name]) throw new Error(`missing --${name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`);
  }
}

class Supervisor {
  constructor(opts, p) {
    this.opts = opts;
    this.p = p;
    this.heartbeatTimeoutMs = Number(opts.heartbeatTimeoutMs || DEFAULT_HEARTBEAT_TIMEOUT_MS);
    this.pollMs = Number(opts.pollMs || DEFAULT_POLL_MS);
    this.state = readJson(p.stateFile, { cursor: 0, nextMessageId: 1, sessions: {} });
    this.delivered = new Set();
    this.server = null;
    this.timer = null;
  }

  save() { writeJson(this.p.stateFile, this.state); }

  attach({ team, name, session }) {
    const key = `${team}/${name}/${session}`;
    this.state.sessions[key] = { team, name, session, lastHeartbeat: Date.now(), status: "live" };
    this.save();
    appendEvent(this.p, "attach", { team, name, session });
    return this.state.sessions[key];
  }

  heartbeat({ team, name, session }) {
    return this.attach({ team, name, session });
  }

  liveSessionFor(team, name) {
    const now = Date.now();
    const live = Object.values(this.state.sessions)
      .filter((s) => s.team === team && s.name === name && now - s.lastHeartbeat <= this.heartbeatTimeoutMs)
      .sort((a, b) => b.lastHeartbeat - a.lastHeartbeat);
    return live[0] || null;
  }

  markStale() {
    const now = Date.now();
    let changed = false;
    for (const session of Object.values(this.state.sessions)) {
      const next = now - session.lastHeartbeat > this.heartbeatTimeoutMs ? "stale" : "live";
      if (session.status !== next) {
        session.status = next;
        appendEvent(this.p, next === "stale" ? "stale" : "live", {
          team: session.team,
          name: session.name,
          session: session.session,
        });
        changed = true;
      }
    }
    if (changed) this.save();
  }

  deliver(message, session) {
    const delivery = {
      ts: new Date().toISOString(),
      id: message.id,
      team: message.team,
      from: message.from,
      to: message.to,
      session: session.session,
      body: message.body,
    };
    if (this.opts.adapterCmd) {
      const result = childProcess.spawnSync(this.opts.adapterCmd, {
        shell: true,
        encoding: "utf8",
        env: { ...process.env, AGMSG_SUPERVISOR_MESSAGE_JSON: JSON.stringify(delivery) },
      });
      if (result.status !== 0) {
        appendEvent(this.p, "adapter-fail", { id: message.id, status: result.status, stderr: (result.stderr || "").trim() });
        return false;
      }
      appendEvent(this.p, "adapter-ok", {
        id: message.id,
        status: result.status,
        stdout: (result.stdout || "").trim(),
        stderr: (result.stderr || "").trim(),
      });
    }
    appendLine(this.p.adapterLog, JSON.stringify(delivery));
    this.delivered.add(message.id);
    this.state.cursor = Math.max(this.state.cursor || 0, message.id);
    this.save();
    appendEvent(this.p, "deliver", { id: message.id, to: message.to, session: session.session });
    return true;
  }

  tick() {
    this.markStale();
    const messages = readMailbox(this.p.mailboxFile).filter((m) => m.id > (this.state.cursor || 0));
    for (const message of messages) {
      if (this.delivered.has(message.id)) continue;
      const session = this.liveSessionFor(message.team, message.to);
      if (!session) {
        appendEvent(this.p, "hold", { id: message.id, to: message.to, reason: "no-live-session" });
        break;
      }
      if (!this.deliver(message, session)) break;
    }
  }

  status() {
    this.markStale();
    return {
      ok: true,
      pid: process.pid,
      project: this.p.project,
      cursor: this.state.cursor || 0,
      sessions: Object.values(this.state.sessions),
      files: {
        portFile: this.p.portFile,
        lockFile: this.p.lockFile,
        mailboxFile: this.p.mailboxFile,
        stateFile: this.p.stateFile,
        eventLog: this.p.eventLog,
        adapterLog: this.p.adapterLog,
      },
    };
  }

  async start() {
    fs.mkdirSync(this.p.runDir, { recursive: true });
    appendEvent(this.p, "start", { pid: process.pid, project: this.p.project });

    this.server = http.createServer((req, res) => {
      const chunks = [];
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        let body = {};
        try { body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}; }
        catch (_) { body = {}; }
        const reply = (code, value) => {
          const text = JSON.stringify(value);
          res.writeHead(code, { "content-type": "application/json" });
          res.end(text);
        };
        try {
          if (req.method === "GET" && req.url === "/status") reply(200, this.status());
          else if (req.method === "POST" && req.url === "/attach") reply(200, this.attach(body));
          else if (req.method === "POST" && req.url === "/heartbeat") reply(200, this.heartbeat(body));
          else if (req.method === "POST" && req.url === "/message") {
            const nextId = this.state.nextMessageId || 1;
            const msg = { id: nextId, createdAt: new Date().toISOString(), ...body };
            this.state.nextMessageId = nextId + 1;
            this.save();
            appendLine(this.p.mailboxFile, JSON.stringify(msg));
            appendEvent(this.p, "message", { id: msg.id, to: msg.to });
            this.tick();
            reply(200, msg);
          } else if (req.method === "POST" && req.url === "/stop") {
            reply(200, { ok: true });
            setTimeout(() => this.stop(), 20);
          } else reply(404, { error: "not found" });
        } catch (error) {
          reply(500, { error: error.message });
        }
      });
    });

    await new Promise((resolve) => this.server.listen(0, "127.0.0.1", resolve));
    const port = this.server.address().port;
    fs.writeFileSync(this.p.portFile, String(port));
    fs.writeFileSync(this.p.lockFile, JSON.stringify({ pid: process.pid, port, project: this.p.project }));
    this.timer = setInterval(() => this.tick(), this.pollMs);
    if (this.timer.unref) this.timer.unref();
    console.log(`status=started port=${port} pid=${process.pid}`);
  }

  stop() {
    appendEvent(this.p, "stop", { pid: process.pid });
    if (this.timer) clearInterval(this.timer);
    try { fs.unlinkSync(this.p.portFile); } catch (_) {}
    try { fs.unlinkSync(this.p.lockFile); } catch (_) {}
    if (this.server) this.server.close(() => process.exit(0));
    else process.exit(0);
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!opts.command || opts.help) { usage(); return; }
  const p = paths(opts);

  if (opts.command === "start") {
    const port = await probeExisting(p);
    if (port) throw new Error(`supervisor already running on port ${port}`);
    const supervisor = new Supervisor(opts, p);
    await supervisor.start();
    return;
  }

  const port = readPort(p);
  if (opts.command === "attach") {
    requireFields(opts, ["team", "name", "session"]);
    console.log(JSON.stringify(await request(port, "POST", "/attach", opts), null, 2));
  } else if (opts.command === "heartbeat") {
    requireFields(opts, ["team", "name", "session"]);
    console.log(JSON.stringify(await request(port, "POST", "/heartbeat", opts), null, 2));
  } else if (opts.command === "send") {
    requireFields(opts, ["team", "from", "to", "body"]);
    console.log(JSON.stringify(await request(port, "POST", "/message", opts), null, 2));
  } else if (opts.command === "status") {
    console.log(JSON.stringify(await request(port, "GET", "/status"), null, 2));
  } else if (opts.command === "stop") {
    console.log(JSON.stringify(await request(port, "POST", "/stop"), null, 2));
  } else {
    throw new Error(`unknown command: ${opts.command}`);
  }
}

main().catch((error) => {
  console.error(`delivery-supervisor: ${error.message}`);
  process.exit(1);
});
