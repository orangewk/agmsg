# Driver Interface Specification

**Status:** draft (epic [#51](https://github.com/fujibee/agmsg/issues/51))
**Scope:** axis A — storage. The common protocol sections also apply to axes B (agent) and C (delivery) but their axis-specific functions are out of scope here.

This document defines the contract between agmsg core and a storage driver. It is the authoritative source for what any new driver must implement.

**v1 scope:** bundled drivers only. The plugin path (`~/.agents/agmsg/plugins/`), `plugin.json` metadata, and `min_core_version` gating are deferred to a future revision; see §6.

## 1. Common driver protocol

These conventions apply to every driver on every axis.

### 1.1 Driver location

Bundled drivers live at `scripts/drivers/<axis>/<name>`. File-based axes use a single `<name>.sh`; the agent-type ("types") axis uses a directory `scripts/drivers/types/<name>/` holding a `type.conf` manifest plus the type's runtime. Their metadata is implicit and tied to the agmsg core version.

External (non-bundled) drivers are discovered from `<install_dir>/plugins/<axis>/<name>` and from `$AGMSG_PLUGIN_DIRS`, and must be opted into — see [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md).

### 1.2 Calling convention

Drivers are bash scripts that agmsg core `source`s and then calls by function name. Function names are prefixed by axis to avoid collisions: storage drivers expose `storage_*` functions, agent drivers expose `agent_*`, delivery drivers expose `delivery_*`.

Drivers must not pollute the global namespace beyond their prefix and must not define `set -e`/`set -u` semantics; those are the caller's responsibility.

### 1.3 Required common functions

Every driver, on every axis, implements:

| Function | Purpose | Returns |
|---|---|---|
| `<axis>_check` | Verify that all runtime dependencies are present and the driver can activate. May emit an `AGMSG-DIRECTIVE` on stdout when a dependency is missing. | status code (see §1.4) |
| `<axis>_describe` | Print a one-line human-readable description on stdout. | always 0 |

### 1.4 Status codes

Driver functions that can fail report a structured status by exit code **and** by printing the status name on stdout as the last line. The status names are:

| Code | Name | Meaning |
|---|---|---|
| 0 | `ok` | Operation succeeded |
| 10 | `missing_deps` | A required external dependency is not installed. An `AGMSG-DIRECTIVE` describing the install was emitted on stdout. |
| 12 | `corrupt_state` | Driver detected unrecoverable inconsistency in its data store. Manual intervention required. |
| 13 | `runtime_error` | Any other failure. stderr contains the message. |

(Code `11 incompatible_core` is reserved for the future plugin loader; not used in v1.)

Callers may treat any non-zero exit as failure, but the status name is the source of truth for the host agent's reaction.

### 1.6 `AGMSG-DIRECTIVE`

A single line written to stdout, prefixed with `AGMSG-DIRECTIVE: ` followed by a JSON object. The host agent reads, parses, and acts on the directive.

```
AGMSG-DIRECTIVE: {"type":"install_deps","driver":"jsonl-duckdb","commands":["brew install duckdb"],"reason":"duckdb binary not found on PATH"}
```

| Field | Type | Description |
|---|---|---|
| `type` | string | One of `install_deps`, `invoke_monitor`, `stop_task`. Extensible. |
| `driver` | string | The driver name emitting the directive (when applicable) |
| `commands` | string[] | Shell commands the host agent may run, in order. Optional. |
| `reason` | string | Human-readable explanation for the user. |
| `*` | any | Type-specific fields; consult the per-type schema in this document. |

Directives are advisory: the host agent decides whether to surface them to the user, run them automatically, or ignore them.

## 2. Storage driver

The storage axis is **messages only**: the durable message log and its read /
replay state. The team registry (`teams/<team>/config.json`) and run-state
(pidfiles, the per-session delivery cursor, actas locks, ready sentinels) are
**not** part of this contract — they stay file-based and form a separate axis
(see [ADR 0003](../adr/0003-storage-axis-driver-abi-and-scope.md)). A storage driver
must implement the *entire* contract below: "this driver does only messages,
that one also does teams" is disallowed, because a partial implementation breaks
the swap-ability the axis exists for.

### 2.1 Required functions

```
storage_check
storage_describe
storage_init
storage_send <team> <from> <to> <body>
storage_list_unread <team> <agent> [--limit N]
storage_mark_read_batch <team> <agent> <id> [<id> ...]
storage_watch_tip <team:agent> [<team:agent> ...]
storage_watch_after <cursor> <team:agent> [<team:agent> ...]
storage_history <team> <agent> [--limit N]
storage_export <file>
storage_import <file>
storage_compact                # internal; see §2.7
```

Every record carries `id` (UUIDv7 for new writes, an opaque string for legacy
ids) and `at` (ISO-8601 UTC). `storage_send` prints the new message's `id` on a
single line. The `watch_*` pair is defined in §2.2.

**stdout framing.** The **control ops** — `storage_check`, `storage_init`,
`storage_mark_read_batch`, `storage_describe`, `storage_compact` — **must** use
the §1.4 convention: a status name (`ok` / `missing_deps` / `runtime_error` / …)
on the last stdout line, with the matching exit code. The **record-returning
ops** — `storage_send`, `storage_list_unread`, `storage_history`,
`storage_watch_tip`, `storage_watch_after` — write **data only** to stdout (JSONL
records, or a bare id / cursor token; one record per line) and signal outcome
with the **exit code** alone: `0` on success, non-zero with a message on
**stderr** on failure. They never emit a §1.4 status name to stdout, so a status
word can never be misread as a record. The trailing `cursor` record of
`storage_watch_after` is part of that data stream (a designated final line), not
a status.

### 2.2 Delivery cursor (watch / replay)

Live delivery (`watch.sh`, `check-inbox.sh`) resumes from a checkpoint instead of
re-reading the whole log. That checkpoint is an **opaque, driver-issued cursor**
— a position in the driver's global message order. Core treats it as an opaque
string: it persists the latest cursor (per session — the successor to the old
`watch.<sid>.watermark` file) and passes it back unchanged. **Core never parses,
compares, or orders cursors.** This is what lets one contract serve sqlite
integer ids, UUIDv7, Redis stream ids, and JSONL byte offsets — the
`id > watermark` integer assumption is removed from core entirely.

The cursor is opaque to core but constrained for transport: it must be a
**single-line, whitespace-free, printable token** that survives being written to
a run-dir file and passed back as one `argv` argument to the sourced driver.
Native positions that already satisfy this (a sqlite integer `seq`, a Redis
stream id) are used as-is; a driver whose native position carries unsafe
characters (e.g. a JSONL byte offset bundled with metadata) must encode it
(base64url or similar) into a single safe token.

- `storage_watch_tip <pairs...>` — print the cursor for "now" (the current tip of
  the global order) as a single bare line. A fresh watcher starts here, so it
  delivers only messages that arrive *after* it attached (no history replay; the
  no-arg inbox check covers the backlog).
- `storage_watch_after <cursor> <pairs...>` — print, as JSONL and in delivery
  order, every `message_sent` after `<cursor>` addressed to one of the
  subscription pairs; then print a final cursor record
  `{"type":"cursor","cursor":"<opaque>"}` as the last line. That trailing cursor
  is the **global tip the driver can safely resume from at call time** (the same
  notion as `storage_watch_tip`) — *not* the cursor of the last matching message.
  It is always emitted, and advances even when zero subscription messages fell in
  the range, so a watcher behind heavy off-subscription traffic does not re-scan
  the same span on every poll. Poll-once: it returns what is currently available
  and exits — core loops on its own interval; a streaming backend may implement
  it as one non-blocking drain.

Each `<pair>` is `<team>:<agent>`. Team and agent names cannot contain `:` (the
name rules enforce this); a driver may additionally reject a pair it cannot split
unambiguously.

### 2.3 Event log schema

The bundled drivers represent state as an append-only event log. Each event is
one record with a `type` discriminator — and only these two types live in the
storage axis (team membership does not; see the §2 intro):

```jsonl
{"type":"message_sent","id":"0192...","team":"agsuite","from":"aggie-cc","to":"aggie-co","body":"...","at":"2026-05-30T19:00:00Z"}
{"type":"message_read","id":"0192...","msg_id":"0192...","team":"agsuite","agent":"aggie-co","at":"2026-05-30T19:05:00Z"}
```

`storage_list_unread <team> <agent>` returns the `message_sent` events addressed
to `<agent>` in `<team>` that have no matching `message_read` for that same
`(team, agent)`. Read-marking is **recipient-scoped**: a `message_read` names the
`(team, agent)` that read the message, so marking one recipient's copy never
affects another's, and re-marking an already-read id is **idempotent** (a no-op,
or a duplicate event the projection collapses).

### 2.4 Legacy compatibility (sqlite only)

The bundled sqlite driver reads two sources for `storage_list_unread` and
`storage_history`:

1. the legacy `messages` table (rows where `read_at IS NULL`) for installs that
   predate the event log, and
2. the event-log tables for everything written after.

Writes target the event log. There is no automated migration; legacy rows stay
queryable indefinitely. Legacy integer ids are passed through as decimal strings
(opaque, per §2.5).

### 2.5 Identifiers

IDs that drivers generate for new writes are **UUIDv7** strings. The interface
treats every id as opaque, so a driver reading legacy data (sqlite autoincrement
ints) passes them through as decimal strings. UUIDv7 is generated inside the
driver (`python -c "..."`, a `uuidgen` that supports v7, or a shell
implementation); drivers must not depend on a counter file. The delivery cursor
(§2.2) is a **separate** opaque token from message ids — a driver may build it
from ids, byte offsets, or stream positions.

### 2.6 Concurrency

Drivers own the concurrency model of their backing store:

- the sqlite driver relies on SQLite's WAL mode;
- a `jsonl` / `duckdb` driver uses a lockfile around mark-read sequences and
  around `compact` / `export` / `import`; single appends may rely on POSIX append
  atomicity for writes ≤ `PIPE_BUF` bytes.

### 2.7 Compaction

The event log grows unbounded. Drivers implement an internal `storage_compact`
that collapses redundant events (coalescing repeated `message_read` markers for
the same `(msg_id, team, agent)`). v1 exposes this only internally; a user-facing
CLI may follow.

## 3. CLI mapping

| User command | Driver function(s) |
|---|---|
| `agmsg storage` | `storage_describe` of active driver |
| `agmsg storage list` | iterate available drivers, call `<axis>_describe` per driver |
| `agmsg storage switch <name>` | new driver's `storage_check`; on `ok`, update config; on `missing_deps`, propagate directive without switching |
| `agmsg storage convert <to>` | new driver's `storage_check`; if `ok`, current `storage_export` → temp → new `storage_import` → verify → atomic config update |
| `agmsg storage export <file>` | active driver's `storage_export` |
| `agmsg storage import <file>` | active driver's `storage_import` |

## 4. Config

Active driver per axis is recorded in `~/.agents/agmsg/config.json`:

```json
{
  "storage": "sqlite",
  "delivery": { "claude-code": "monitor", "codex": "turn" }
}
```

`storage` is a single string (machine-wide). `delivery` is per agent type because runtimes differ in available delivery mechanisms. `agent` is implicit from the per-invocation `<type>` argument.

## 5. Out of scope (deferred)

- **Plugin loader** — external-driver discovery (`<install_dir>/plugins/`, `$AGMSG_PLUGIN_DIRS`) and the opt-in trust model are now defined by [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md). Still deferred from that loader: `plugin.json` metadata parsing, `min_core_version` gating, and the `incompatible_core` status code.
- **Plugin signing or sandboxing** — orthogonal to the loader; would be addressed when the loader lands.
- **Per-project active driver override** — v1 is machine-wide; future enhancement.
- **Subcommand + JSONL-pipe driver protocol** (language-independent drivers) — deferred until a non-bash driver is actually wanted.
- **Cross-machine storage drivers** (postgres, s3-jsonl) — not blocked by this spec; can be added under the same protocol when needed.
