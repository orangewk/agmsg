"use strict";

// manifest.js — Node counterpart to lib/manifest.sh.
//
// Same ledger, same file (`$SKILL_DIR/run/manifest.jsonl`), same line shape.
// Exists separately (not shelled out to manifest.sh) because a Node-launched
// delivery role — currently only codex-bridge.js — reports its OWN identity
// (`process.pid`) which lives in a DIFFERENT pid space than what a calling
// bash script's `$!` would see (see the PID SPACE note below); a JS writer
// avoids a round-trip through bash just to stringify that same process's own
// pid, and keeps the "what pid space is this" decision co-located with the
// code that actually knows which one it is.
//
// PID SPACE: codex-bridge.js is launched as `nohup node ... &`. `nohup`
// interposes a bash subshell, so the LAUNCHING script's `$!` is that
// subshell's MSYS pid — NOT this process. The only pid this process can
// truthfully report for itself is `process.pid`, which Node reports in
// Windows-native space. So every entry this file writes is
// `"pidSpace":"native"`. A reader (gc.sh) must check liveness/cmdline via
// instance-id.sh's _agmsg_pid_alive (tasklist) and compat.sh's
// compat_get_native_cmdline (CIM by native pid directly) — NOT kill -0 /
// compat_get_cmdline, confirmed empirically to fail on a native pid.

const fs = require("fs");
const path = require("path");

function manifestPath(runDir) {
  return path.join(runDir, "manifest.jsonl");
}

function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, "Z");
}

function jsonEscape(value) {
  return String(value == null ? "" : value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\r/g, "")
    .replace(/\n/g, " ");
}

// Best-effort append, mirroring manifest.sh's contract: a manifest write
// failure must never break the caller's actual job (running the bridge).
function appendLine(runDir, obj) {
  try {
    fs.mkdirSync(runDir, { recursive: true });
    fs.appendFileSync(manifestPath(runDir), JSON.stringify(obj) + "\n");
  } catch (_) {
    // Degraded observability only — gc won't reap this if abandoned. Not a
    // reason to fail the bridge's actual delivery job.
  }
}

// Record that this process (identified by its OWN native pid) now exists as
// a delivery-role artifact. cmdline should be a stable, re-derivable string
// (process.argv.join(" ") is used by the one caller so far) so a later
// liveness check can positively confirm "still the same process", not just
// "some process holds this pid" (Windows recycles pids aggressively).
function recordProcessCreate(runDir, { pid, cmdline, createdBy, disposeHint }) {
  appendLine(runDir, {
    ts: nowIso(),
    event: "create",
    kind: "process",
    id: {
      pid: String(pid),
      pidSpace: "native",
      cmdline: cmdline || "",
      startedAt: nowIso(),
    },
    createdBy: createdBy || "",
    disposeHint: disposeHint || "",
  });
}

// Record disposal counterpart. Called from the process's own exit path — see
// codex-bridge.js's cleanupMeta().
function recordProcessDispose(runDir, { pid, disposedBy }) {
  appendLine(runDir, {
    ts: nowIso(),
    event: "dispose",
    kind: "process",
    id: { pid: String(pid), pidSpace: "native" },
    disposedBy: disposedBy || "",
  });
}

// Record a kind=state-file create event (see manifest.sh's manifest_record_create
// / manifest_state_file_id bash counterparts — spawn.sh's SPAWN_REC boot
// script uses the same kind). `path` is a single representative file for a
// set of state files a caller writes together (e.g. the codex-app-server
// owner's pid/port/endpoint/log quartet); this mirrors gc.sh's own
// one-pidfile-names-a-set convention rather than inventing a new
// multi-path id shape.
function recordStateFileCreate(runDir, { path: filePath, createdBy, disposeHint }) {
  appendLine(runDir, {
    ts: nowIso(),
    event: "create",
    kind: "state-file",
    id: { path: filePath || "" },
    createdBy: createdBy || "",
    disposeHint: disposeHint || "",
  });
}

// Record a kind=state-file dispose event.
function recordStateFileDispose(runDir, { path: filePath, disposedBy }) {
  appendLine(runDir, {
    ts: nowIso(),
    event: "dispose",
    kind: "state-file",
    id: { path: filePath || "" },
    disposedBy: disposedBy || "",
  });
}

module.exports = {
  manifestPath,
  jsonEscape,
  recordProcessCreate,
  recordProcessDispose,
  recordStateFileCreate,
  recordStateFileDispose,
};
