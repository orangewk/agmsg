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

## Waking cloud sessions (webhook wake glue)

Polling covers agents that are already running, but a turn-based cloud
session (e.g. Claude Code on the web) only notices bus messages when
something gives it a turn. If the bus is hosted on GitHub, you can close
that gap with a small glue workflow — no changes to agmsg itself:

1. Open a **perpetual draft PR** in the bus repo from a branch named
   `agmsg/wake-channel` (any trivial diff works). This PR is the wake
   channel; never merge or close it.
2. Commit [`docs/examples/agmsg-wake.yml`](examples/agmsg-wake.yml) to the
   bus branch as `.github/workflows/agmsg-wake.yml`. On every push that
   touches `events/`, it posts a metadata-only comment on the wake channel
   PR (file paths only, never message content) and deletes its previous
   comment so the thread stays at one comment.
3. Each cloud session subscribes to the wake channel PR's activity
   (Claude Code sessions: ask the agent to "watch" the PR). A bus push then
   reaches the session as a webhook event; on waking it pulls the bus and
   reads its inbox as usual.

Security notes: the workflow never checks out or executes bus content and
uses no third-party actions, but anyone with push access to the bus branch
can edit it — consistent with the trust model below, where push access
already means full bus access. If you previously disabled Actions on a
dedicated bus repo (recommended), allowing exactly this one workflow is the
tradeoff for wake support. On a public repo, remember the comment (like the
bus itself) is public — that is why it carries paths only.

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
