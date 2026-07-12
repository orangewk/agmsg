# ADR 0005: Multi-environment messaging over a git-backed event bus

**Status:** proposed
**Date:** 2026-07-12
**Deciders:** @orangewk

## Context

agmsg today is single-machine by design: messages move through local files, and
delivery rides the host runtime's hooks. But agents increasingly live in
*different environments* — a laptop, a desktop, Claude Code on the web, Codex
cloud sandboxes — and we want any of them to message any other.

The environments impose hard constraints:

1. **Cloud sandboxes are outbound-HTTPS-only.** No inbound ports, no
   daemons that outlive the session, ephemeral disks. Anything requiring a
   listening socket or ssh into the sandbox is out.
2. **No push channel into a sandbox.** The only way a sandboxed agent learns
   of a new message is by checking — which agmsg already does on every Stop
   hook (`check-inbox.sh`).
3. **The one credential that exists in essentially every agent environment
   is git access to a hosting service (GitHub).** Local machines, Claude
   Code web, Codex cloud — all can clone/push a private repo. No other
   transport (Slack tokens, MQTT brokers, custom relays) is universally
   pre-provisioned.
4. The default install promise — **bash + sqlite3 only** — must survive.
   Remote messaging must be opt-in.

Separately, the bundled storage drivers already represent state as an
**append-only event log with UUIDv7 ids** (ADR 0001), which was chosen
partly *because* it is "friendlier for cross-machine sync via git/rsync".
This ADR cashes in that design.

## Decision

Add a fourth axis, **transport**, with bundled drivers `none` (default) and
`git`. The `git` driver replicates the local event log through a private
git repository — the "bus repo" — using append-only, per-writer JSONL files.

Shape of the design:

- **One private repo per team** (or one repo with a directory per team),
  e.g. `orangewk/agmsg-bus`. Configured via `agmsg remote add <git-url>`.
- **Layout:** `events/<team>/<agent>/<env-id>.jsonl`. Each *(agent,
  environment)* pair appends only to its own file. Because no two writers
  ever touch the same file, pushes can only race on the ref, never on
  content; a fetch + rebase + retry loop resolves every collision
  mechanically.
- **Events are the same events the local store already records**
  (`message_sent`, `message_read`, …), with the same UUIDv7 ids. Sync is
  therefore a *union of event sets, deduplicated by id* — idempotent,
  order-tolerant, restartable. Read-receipts replicate for free, so a
  sender in one environment sees delivery confirmation from another.
- **Send path:** `send.sh` writes the local event as today, then appends it
  to this writer's bus file, commits, and pushes (backgrounded,
  retry-with-backoff). If offline, nothing is lost: a cursor records the
  last exported event id, and the next sync pushes the backlog.
- **Receive path:** `check-inbox.sh` runs `sync pull` (git fetch + import
  events not yet seen, dedupe by id) before its existing unread query. The
  local storage driver remains the sole query engine; delivery drivers
  (`monitor`/`turn`/`both`) work unchanged. Latency is the existing
  `hook.check_interval` plus one git round trip — seconds, not
  milliseconds, which matches agent conversational cadence.
- **Identity is unchanged:** agents remain `(name, team)`. The environment
  id (hostname or sandbox id) is metadata on events and names the writer
  file; the same agent name in two environments is the same logical agent,
  consistent with the direction of issue #15.
- **Auth:** per-environment fine-grained PAT or deploy key scoped to the
  bus repo only. In managed sandboxes (Claude Code web), the bus repo is
  added to the session's repository scope.
- **Growth control:** writer files rotate monthly
  (`<env-id>.<yyyymm>.jsonl`); old months can be snapshotted and pruned by
  rotating to a fresh orphan branch.

The transport axis follows the driver protocol from ADR 0001/0002:
`transport_check` / `transport_describe`, structured status codes, and
`AGMSG-DIRECTIVE` when git or credentials are missing. Default `none`
preserves the bash + sqlite3-only install.

Optional, later: a **wake accelerator** for environments that can hold a
process — `watch.sh` long-polling an ntfy.sh topic (or the hosting API with
ETags) to trigger a sync ahead of the next hook tick. Notification only;
the git repo stays the source of truth.

## Alternatives considered

- **Hosted relay (small REST/SSE service on a VPS or Cloudflare Worker).**
  Lowest latency and a real push channel. Rejected as the *first* transport:
  it is infrastructure to run, secure, and pay for, plus a secret to
  distribute to every environment. The transport axis leaves room to add it
  as a driver later without re-architecting.
- **ntfy.sh / MQTT pub-sub as the bus.** Excellent for notification, but no
  durable store, no history, no read-model — we would rebuild storage on
  top of a firehose. Retained only as the optional wake accelerator.
- **Slack (or Discord) as the bus.** Human-visible, which is charming, but
  requires per-environment tokens, has rate limits, and mangles structured
  payloads. A Slack *bridge* (mirroring agmsg traffic into a channel) is a
  separate feature, not the transport.
- **GitHub Issues/comments as the bus.** API-writable from anywhere, but
  noisy, rate-limited, and loses git's offline/append semantics that our
  event log already matches.
- **rsync/ssh between machines.** Fails constraint 1 — sandboxes accept no
  inbound connections and offer no stable ssh identity.
- **A shared cloud database.** Violates the project's founding "no shared
  cloud, no daemon" stance for local use; as an opt-in transport it is
  strictly more setup than a private repo for no capability gain at this
  scale.
- **Do nothing.** Multi-environment agents are the present, not the future;
  the event-log storage design was explicitly chosen to enable this.

## Consequences

- Positive: any two agmsg agents with credentials to the same private repo
  can message each other from anywhere — laptop ↔ cloud sandbox included —
  with zero servers to operate. Sync is idempotent and offline-tolerant by
  construction. Full message history is auditable in git.
- Positive: read receipts and future event types replicate automatically;
  the local query/delivery machinery is untouched.
- Negative: latency is polling-bound (roughly `hook.check_interval` +
  git round trip), not real-time. Acceptable for agent turn cadence;
  the wake accelerator exists for tighter loops.
- Negative: message bodies live permanently in git history on the hosting
  service. The bus repo must be private, and users must treat it as a
  durable record; true deletion requires history rewrite or branch
  rotation.
- Negative: a fourth axis adds surface area — config, docs, discovery — and
  per-environment credential provisioning is a real setup step.
- Neutral: hosting-service rate limits bound message throughput; at
  human-team scale (tens of messages/minute) this is far from any limit.

## References

- [ADR 0001](0001-storage-driver-pluginization.md) — event-log storage,
  driver protocol, the "cross-machine sync via git" motivation
- [ADR 0002](0002-driver-discovery-and-plugin-opt-in.md) — discovery and
  opt-in conventions the transport axis reuses
- Issue #15 — identity redesign (agent identity spans environments)
