# ADR 0006: Notification layer — event classes and subscriber routing

**Status:** accepted
**Date:** 2026-07-14
**Deciders:** @orangewk

## Context

ADR 0005 gave agmsg a transport: environments replicate messages through a
git bus of append-only writer files. What it did not give is a way to *wake*
a recipient that is not already polling. Turn-based cloud sessions (Claude
Code on the web and similar) only notice bus messages when something gives
them a turn.

A first spike closed the gap mechanically: a GitHub Action on the bus branch
posted a comment on a perpetual "wake channel" PR on every push, and cloud
sessions subscribed to that PR's activity. It worked end-to-end — and one day
of dogfooding surfaced the design flaw. The Action reacted to the *transport
phenomenon* ("a push happened") when the thing we mean is a *semantic* one
("a new message arrived for recipient X"). Every gap between those two
statements demanded a patch:

- Read receipts (`message_read`, ADR 0005 + issue #16) live on the same bus,
  so delivering one message woke every subscriber **twice** — once for the
  message, once for the reader's receipt push.
- An environment was woken by its own pushes.
- There was no way to wake only the recipient; every event woke everyone.

The candidate patches — mark receipts-only pushes in the commit message so
the Action can skip them, have woken sessions inspect file paths to ignore
their own writes — each smuggle information a missing layer should own
through a channel that should not carry it.

## Decision

Introduce an explicit **notification layer** on top of the transport, in two
parts, and require each part to be statable in one sentence.

**Event classes (semantics).** Every event type belongs to exactly one class,
declared in the table below. New event types must declare theirs.

| Class | Event types | On the bus | Wakes someone |
|---|---|---|---|
| **deliverable** | `message_sent` (and legacy lines with no `type`) | yes | the recipient only |
| **state gossip** | `message_read` | yes | no one — it converges whenever the peer next syncs |

**Subscriber routing (delivery).** The bus carries a registry alongside the
events — one JSON file per (team, agent) that says who wants to be woken and
how:

```
subscribers/<team>/<agent>.json
{
  "env":    "<registrant's env id>",
  "filter": { "team": "<team>", "to": "<agent>" },
  "wake":   { "kind": "pr-comment", "pr": <number> }
}
```

A **router** (a GitHub Action on the bus branch) runs on every push. Its
whole contract: *read the metadata of newly appended event lines, and
deliver only deliverables, to subscribers whose filter matches and who are
not the writer, via their registered wake kind.* It checks out nothing,
executes nothing from the bus, and emits only metadata (never message
bodies). Delivery failures are logged, not fatal — wake is best-effort
sugar on top of a transport that already works by polling.

`wake.kind` is the replaceable part. `pr-comment` (comment on an open PR the
session watches) is the first implementation because it is the only
session-waking primitive available today. When a host-level wake API exists
(the MathDesk-side boundary discussed in fujibee/agmsg#374), it becomes a new
`kind`; migrating is editing the registry entry, not redesigning the layer.

Environments register with `remote.sh subscribe <team> <agent> --pr <n>` and
leave with `remote.sh unsubscribe <team> <agent>`.

## Alternatives considered

- **Keep the broadcast spike and patch it.** Receipts-only markers in commit
  messages, self-filtering by path on the woken side. Rejected: each patch
  moves layer-2/3 information through a channel that shouldn't carry it, and
  the patch list was still growing after one day of use.
- **Do nothing (polling only).** Rejected for cloud sessions: the whole
  point is delivery *between* turns; monitor-mode polling covers only
  environments that are already running.
- **Wake logic in the sender** (sender comments on the recipient's PR
  directly). Rejected: every environment would need credentials and code for
  every wake kind, and offline senders can't retry. The bus already sees
  every event exactly once; the router is the single natural choke point.
- **Registry outside the bus** (repo variables, a config file in the code
  repo). Rejected: the bus is already the one shared place every environment
  can read and write; a second registry means a second thing to provision.

## Consequences

- Positive: one message wakes exactly one subscriber exactly once. Receipts
  wake no one. An environment is never woken by its own writes. Multiple
  sessions are each woken via their own registry entry. All of yesterday's
  symptoms disappear from the design rather than being patched over.
- Positive: layer boundaries are testable sentences — the transport doesn't
  change, the class table is a constant, the router only reads metadata and
  the registry.
- Negative: the router must parse newly added event lines (via the compare
  API) to read their metadata; the bus content passes through it even though
  only metadata is used. On a public bus repo, subscriber names, team names
  and counts appear in wake comments — same exposure class as the writer
  file paths themselves.
- Negative: one registry entry per (team, agent) means one wake target per
  agent identity. This matches the single-personality model (the same agent
  replicated across environments shares read state too); an agent that wants
  waking in several environments at once needs per-environment agent names.
- Neutral: anyone with push access to the bus can edit the registry and the
  router — unchanged from ADR 0005's trust model, where push access already
  means full bus access.

## References

- ADR 0005 (transport), issue #16 / PR #21 (read receipts)
- fujibee/agmsg#374 (host-side wake boundary; future `wake.kind`)
- PR #23 (first wake channel PR), PR #24 (implementation)
