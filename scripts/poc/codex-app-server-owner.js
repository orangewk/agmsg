#!/usr/bin/env node
"use strict";

const childProcess = require("child_process");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

// Lifecycle wiring (orangewk/agmsg#8, WP3a): this owner spawns a delivery-role
// process (the shared codex app-server) and writes delivery-role state files
// (pid/port/endpoint/log). Both must show up in the SAME repo-wide ledger
// every other delivery-role artifact uses ($SKILL_DIR/run/manifest.jsonl),
// not under this script's OWN --run-dir (which is PoC-local and can be
// anywhere) — otherwise gc.sh's reap-on-startup pass and `delivery.sh set
// off` never see this PoC's artifacts at all, which is exactly the residue
// problem #8 opened on. Only the LEDGER path is repo-wide; --run-dir keeps
// owning this script's own pid/port/endpoint/log files, unchanged.
const manifest = require(path.join(__dirname, "..", "lib", "manifest.js"));

function repoRoot() {
  return path.resolve(__dirname, "..", "..");
}

// Where the shared manifest.jsonl ledger lives. See delivery-supervisor.js's
// identical helper for why this needs an override: without it, every test run
// that actually starts an owner-managed process appends real lines into this
// repo's own (untracked, non-gitignored) run/manifest.jsonl instead of an
// isolated fixture dir. AGMSG_SKILL_DIR mirrors the bash test harness's own
// SKILL_DIR override convention.
function skillRunDir() {
  const override = process.env.AGMSG_SKILL_DIR;
  return path.join(override ? path.resolve(override) : repoRoot(), "run");
}

function usage() {
  console.log(`Usage: codex-app-server-owner.js start --run-dir <path> [--port <n>] [--codex <path>]\n       codex-app-server-owner.js stop --run-dir <path>`);
}

function parseArgs(argv) {
  const opts = { command: argv[0] || "" };
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") opts.help = true;
    else if (arg === "--run-dir") opts.runDir = argv[++i];
    else if (arg === "--port") opts.port = Number(argv[++i]);
    else if (arg === "--codex") opts.codex = argv[++i];
    else throw new Error(`unknown argument: ${arg}`);
  }
  return opts;
}

function defaultCodex() {
  if (process.platform === "win32") {
    const nativeExe = path.join(
      os.homedir(),
      "AppData",
      "Roaming",
      "npm",
      "node_modules",
      "@openai",
      "codex",
      "node_modules",
      "@openai",
      "codex-win32-x64",
      "vendor",
      "x86_64-pc-windows-msvc",
      "bin",
      "codex.exe",
    );
    if (fs.existsSync(nativeExe)) return nativeExe;
    return path.join(os.homedir(), "AppData", "Roaming", "npm", "codex.ps1");
  }
  return "codex";
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

function waitPort(port, timeoutMs = 7000) {
  return new Promise((resolve) => {
    const deadline = Date.now() + timeoutMs;
    const tryOnce = () => {
      const socket = net.createConnection({ host: "127.0.0.1", port });
      socket.on("connect", () => { socket.destroy(); resolve(true); });
      socket.on("error", () => {
        socket.destroy();
        if (Date.now() >= deadline) resolve(false);
        else setTimeout(tryOnce, 100);
      });
    };
    tryOnce();
  });
}

function paths(runDir) {
  const dir = path.resolve(runDir || path.join(process.cwd(), "run", "poc-codex-app-server"));
  return {
    dir,
    pidFile: path.join(dir, "codex-app-server.pid"),
    portFile: path.join(dir, "codex-app-server.port"),
    endpointFile: path.join(dir, "codex-app-server.endpoint"),
    logFile: path.join(dir, "codex-app-server.log"),
  };
}

function spawnCodex(codex, args, logFile) {
  const stdout = fs.openSync(logFile, "a");
  const stderr = fs.openSync(logFile, "a");
  if (process.platform === "win32" && codex.toLowerCase().endsWith(".ps1")) {
    return childProcess.spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", codex, ...args], {
      stdio: ["ignore", stdout, stderr],
      detached: false,
      windowsHide: true,
    });
  }
  return childProcess.spawn(codex, args, {
    stdio: ["ignore", stdout, stderr],
    detached: process.platform === "win32",
    windowsHide: true,
  });
}

function readPid(file) {
  try { return Number(fs.readFileSync(file, "utf8").trim()); }
  catch (_) { return 0; }
}

async function start(opts) {
  const p = paths(opts.runDir);
  fs.mkdirSync(p.dir, { recursive: true });
  const port = opts.port || await freePort();
  const endpoint = `ws://127.0.0.1:${port}`;
  const codex = opts.codex || defaultCodex();
  const child = spawnCodex(codex, ["app-server", "--listen", endpoint], p.logFile);
  child.unref();
  fs.writeFileSync(p.pidFile, `${child.pid}\n`);
  fs.writeFileSync(p.portFile, `${port}\n`);
  fs.writeFileSync(p.endpointFile, `${endpoint}\n`);
  const open = await waitPort(port);
  if (!open) {
    try { child.kill(); } catch (_) {}
    throw new Error(`app-server did not open ${endpoint}; see ${p.logFile}`);
  }
  // Manifest wiring: the app-server child is a native-pid process (Node
  // reports its own process.pid the same way codex-bridge.js's writeMeta()
  // does — see manifest.sh's PID SPACE DECISION). Record it AND the state
  // files this owner just wrote as one create event each, so gc.sh's
  // reap-on-startup pass and `delivery.sh set off` can find both if this
  // process is later confirmed dead without ever running stop().
  manifest.recordProcessCreate(skillRunDir(), {
    pid: child.pid,
    cmdline: `${codex} app-server --listen ${endpoint}`,
    createdBy: `poc-codex-app-server-owner:${process.pid}`,
    disposeHint: "codex-app-server-owner.js stop (or gc if dead)",
  });
  manifest.recordStateFileCreate(skillRunDir(), {
    path: p.pidFile,
    createdBy: `poc-codex-app-server-owner:${process.pid}`,
    disposeHint: "codex-app-server-owner.js stop (pid/port/endpoint/log set)",
  });
  console.log(JSON.stringify({ ok: true, pid: child.pid, endpoint, logFile: p.logFile }, null, 2));
}

function stop(opts) {
  const p = paths(opts.runDir);
  const pid = readPid(p.pidFile);
  let stopped = false;
  if (pid) {
    try {
      if (process.platform === "win32") {
        childProcess.spawnSync("taskkill.exe", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
      } else {
        process.kill(-pid);
      }
      stopped = true;
    } catch (_) {
      try { process.kill(pid); stopped = true; } catch (__) {}
    }
  }
  if (pid) {
    manifest.recordProcessDispose(skillRunDir(), { pid, disposedBy: "codex-app-server-owner.js stop" });
  }
  manifest.recordStateFileDispose(skillRunDir(), { path: p.pidFile, disposedBy: "codex-app-server-owner.js stop" });
  for (const file of [p.pidFile, p.portFile, p.endpointFile]) {
    try { fs.unlinkSync(file); } catch (_) {}
  }
  console.log(JSON.stringify({ ok: true, stopped, pid }, null, 2));
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help || !opts.command) { usage(); return; }
  if (opts.command === "start") await start(opts);
  else if (opts.command === "stop") stop(opts);
  else throw new Error(`unknown command: ${opts.command}`);
}

main().catch((error) => {
  console.error(`codex-app-server-owner: ${error.message}`);
  process.exit(1);
});




