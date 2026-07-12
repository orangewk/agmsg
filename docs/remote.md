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

That's it. `send.sh` now pushes new messages to the bus in the background,
and the Stop-hook inbox check (and `inbox.sh`) pulls remote messages before
reading, so cross-environment messages arrive through the exact same
delivery path as local ones.

## Commands

```bash
remote.sh add <git-url>   # bind this store to a bus repo (clones it)
remote.sh status          # url, env id, unexported/unpushed counts
remote.sh sync            # pull + import, then export + push
remote.sh pull            # fetch remote events into the local store
remote.sh push            # export local messages and push them out
remote.sh remove          # forget the bus; local messages are kept
```

`sync` is what you run by hand when you want to force a round trip; the
hooks call `pull`/`push` automatically.

## How it works

- Each environment gets an **env id** (`<hostname>-<random>`) at `add` time
  and appends events only to its own writer files on the bus:
  `events/<env-id>.<YYYYMM>.jsonl`. Per-writer files mean two environments
  can never produce a git content conflict; pushes race only on the ref and
  are resolved by an automatic rebase-and-retry.
- Events carry a globally unique id, and import is `INSERT OR IGNORE`
  against a unique index — replaying any file any number of times cannot
  duplicate a message, and offline environments simply catch up on their
  next sync.
- The store gains two nullable columns (`uuid`, `origin`). Existing rows
  and stores that never configure a remote are untouched.

## Latency and limits

Delivery latency is the receiver's hook cooldown
(`delivery.turn.check_interval`, default 60s) plus one git round trip. Git
fetch/push traffic is not metered against the GitHub REST API rate limit;
at agent-team message rates you are orders of magnitude below any abuse
threshold. See the ADR for the full analysis.

## Known limitations (MVP)

- **Read state is per-environment.** `read_at` is not replicated, so an
  agent joined in two environments sees the same message in both. This is
  usually what you want (the message reaches you wherever you're active);
  read-receipt replication is future work.
- Team membership (`teams/` config) is not replicated — join the team in
  each environment with the same team/agent names.
- The bus repo's history is a permanent record; truly deleting a message
  requires history rewriting.
