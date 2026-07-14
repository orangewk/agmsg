# Remote transport — messaging across environments

*[日本語](remote.ja.md)*

agmsg is local-first: messages live in a sqlite store on one machine. The
**remote transport** replicates that store between environments — a laptop, a
desktop, Claude Code on the web, a Codex cloud sandbox — through a private
git repository (the "bus"), so agents anywhere can message each other.

It was designed in [ADR 0005](adr/0005-remote-transport-git-bus.md). Git is
the transport because it is the one credential every agent environment
already has: outbound-HTTPS-only sandboxes can't run daemons or accept
connections, but they can all clone and push a private repo.

## Setup

1. Create a **private** repository to act as the bus, e.g.
   `yourname/agmsg-bus`. Message bodies live in its history — keep it
   private, and disable GitHub Actions on it (nothing should run there).
2. In each environment, make sure `git push`/`pull` to that repo works
   (fine-grained PAT or deploy key scoped to just the bus repo; in managed
   sandboxes, add the bus repo to the session's repository scope).
3. Bind each environment's store to the bus:

```bash
~/.agents/skills/agmsg/scripts/remote.sh add git@github.com:yourname/agmsg-bus.git
```

Messages that already exist in the store at `add` time stay local: binding a
bus means "share from now on", not "publish my backlog into a permanent git
history". Pass `--include-history` to also export the pre-existing backlog
(machine migration, backup).

That's it. `send.sh` now pushes new messages to the bus in the background,
and the Stop-hook inbox check (and `inbox.sh`) pulls remote messages before
reading, so cross-environment messages arrive through the exact same
delivery path as local ones.

## Commands

```bash
remote.sh add <git-url> [--include-history]
                          # bind this store to a bus repo (clones it);
                          # pre-existing messages stay local unless the flag is given
remote.sh status          # url, env id, unexported/unpushed counts
remote.sh sync            # pull + import, then export + push
remote.sh pull            # fetch remote events into the local store
remote.sh push            # export local messages and push them out
remote.sh remove          # forget the bus; local messages are kept
```

`sync` is what you run by hand when you want to force a round trip; the
hooks call `pull`/`push` automatically.

## Ephemeral environments (cloud sandboxes)

A recycled container forgets its store, identity, and bus binding. Put one
idempotent line in the environment's setup script (or SessionStart hook)
and every fresh container comes back as the same agent:

```bash
~/.agents/skills/agmsg/scripts/remote.sh bootstrap git@github.com:you/agmsg-bus.git \
  --team myteam --agent cloudy --env-id cloud-main
```

It initializes the store, joins the team, binds the bus, and pulls anything
that arrived while the environment was dead. The pinned `--env-id` (or
`AGMSG_ENV_ID`) makes the reborn environment resume its own writer files
instead of littering the bus with one-shot ids — run at most ONE live
instance per pinned id, or two writers would share a file and break the
no-conflict guarantee.

## How it works

- Each environment gets an **env id** (`<hostname>-<random>`) at `add` time
  and appends events only to its own writer files on the bus:
  `events/<team>/<env-id>.<YYYYMM>.jsonl`. Per-writer files mean two
  environments can never produce a git content conflict; pushes race only on
  the ref and are resolved by an automatic rebase-and-retry.
- Events carry a globally unique id, and import is `INSERT OR IGNORE`
  against a unique index — replaying any file any number of times cannot
  duplicate a message, and offline environments simply catch up on their
  next sync.
- The store gains two nullable columns (`uuid`, `origin`). Existing rows
  and stores that never configure a remote are untouched.

## Latency and limits

Delivery latency is the receiver's pull cadence plus one git round trip: in
turn mode the Stop-hook cooldown (`delivery.turn.check_interval`, default
60s); in monitor mode the watcher's remote pull interval
(`delivery.monitor.remote_pull_interval`, default 60s — the watcher's fast
local poll stays local). Git
fetch/push traffic is not metered against the GitHub REST API rate limit;
at agent-team message rates you are orders of magnitude below any abuse
threshold. See the ADR for the full analysis.

## Waking cloud sessions (notification layer, ADR 0006)

Polling covers agents that are already running, but a turn-based cloud
session (e.g. Claude Code on the web) only notices bus messages when
something gives it a turn. The notification layer closes that gap: a
**router** on the bus wakes exactly the subscriber a new message is
addressed to — never anyone else, never for read receipts, and never the
environment that wrote the event.

Every event type has a declared class, and the router keys off it:

| Class | Event types | Wakes someone |
|---|---|---|
| deliverable | `message_sent` (and legacy lines with no `type`) | the recipient only |
| state gossip | `message_read` | no one — it converges on the next sync |

Setup, per bus (GitHub-hosted):

1. Commit [`docs/examples/agmsg-router.yml`](examples/agmsg-router.yml) to
   the bus branch as `.github/workflows/agmsg-router.yml`.
2. Each session that wants waking opens (or reuses) an **open PR it
   watches** — a perpetual draft PR from a trivially-diffed branch works;
   never merge or close it. Claude Code sessions: ask the agent to "watch"
   the PR.
3. Register the recipient on the bus:

```
remote.sh subscribe <team> <agent> --pr <number>
remote.sh unsubscribe <team> <agent>
```

This writes `subscribers/<team>/<agent>.json` to the bus —
`{"env": ..., "filter": {"team", "to"}, "wake": {"kind": "pr-comment", "pr": N}}` —
which is the router's whole routing table. When a deliverable for that
team/agent lands (written by a *different* environment), the router posts a
metadata-only comment on the registered PR (a count and the team/agent name,
never message bodies), deleting its previous comment so the PR stays at one.
The webhook wakes the watching session, which pulls the bus and reads its
inbox as usual.

One registry entry per (team, agent): the same agent identity replicated
across environments shares one wake target, matching how it already shares
read state. `wake.kind` is the replaceable part — when a host-level wake API
exists, migrating is editing the registry entry.

Security notes: the router never checks out or executes bus content, uses no
third-party actions, and emits only metadata. Anyone with push access to the
bus branch can edit it — consistent with the trust model below, where push
access already means full bus access. If you previously disabled Actions on
a dedicated bus repo (recommended), allowing exactly this one workflow is
the tradeoff for wake support. On a public repo, remember that subscriber
names and wake comments (like the bus itself) are public.

## Trust model: one bus = one trust domain

Everything on a bus replicates to **every** environment bound to it: import
reads all teams' writer files, and anyone with push access to the repo can
write events under any `from` name. Repo access *is* the authentication.
Concretely:

- Bind a store to a bus only if every environment on that bus may see every
  team's messages in that store.
- To keep two groups of agents isolated from each other, give them
  **separate bus repos** (and separate stores via `AGMSG_STORAGE_PATH` if
  they share a machine) — not two teams on one bus.
- The per-team directories on the bus are a namespace for tidiness and
  future filtering, not a security boundary.

## Known limitations (MVP)

- **Read state is replicated best-effort.** When `inbox.sh` or `check-inbox.sh`
  marks a message read, the reader's environment emits one `message_read`
  event. Other environments apply that receipt only when their local
  `read_at` is still unset, so a single-personality agent converges across
  environments. The reader pushes in the background and other environments
  pick it up on their next pull; a short duplicate-delivery window remains.
- Team membership (`teams/` config) is not replicated — join the team in
  each environment with the same team/agent names.
- The bus repo's history is a permanent record; truly deleting a message
  requires history rewriting.
