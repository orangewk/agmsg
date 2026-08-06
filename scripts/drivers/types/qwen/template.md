---
name: __SKILL_NAME__
description: Cross-agent messaging via SQLite for Qwen Code. Join teams, send and receive messages, and launch peer CLI agents.
---

Use the provided agmsg scripts for all messaging operations. Never read or edit
the database, team files, or config files directly. There is no `register.sh`;
use `join.sh`.

## Shell requirement

All agmsg scripts are Bash scripts. On Windows, use Git Bash rather than the
WindowsApps WSL `bash` shim. From PowerShell, invoke:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -lc '~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" qwen'
```

For the commands below, use the same Git Bash executable when the current shell
is PowerShell. Do not construct database paths yourself.

## Identity

Run:

```bash
~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" qwen
```

Handle the result as follows.

- `agent=<name> teams=<teams> type=qwen ...`: remember the agent and teams.
- `multiple=true ...`: ask which listed identity to use in this session.
- `not_joined=true available_teams=...`: perform first-time setup below.
- `suggest=true ...`: offer the suggested identities, then ask which team to
  join.

### First-time setup

1. Show the available teams and ask for a team name.
2. For an existing team, run
   `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` and propose an
   unused role name that follows its naming pattern.
3. Ask the user to choose the role name.
4. Join with:

   ```bash
   ~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> qwen "$(pwd)"
   ```

5. Ask for the delivery mode using this prompt:

   ```text
   Choose delivery mode for incoming messages:

     1) turn — Check inbox when Qwen finishes a response
                Recommended for Qwen Code.

     2) off  — No automatic delivery
                Manual /__SKILL_NAME__ only.

   [1]:
   ```

6. Map `1` to `turn` and `2` to `off`, then run:

   ```bash
   ~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> qwen "$(pwd)"
   ```

7. Check the new identity's inbox immediately.

Qwen supports `turn` and `off` only. Reject `monitor` and `both`.

## Commands

If `/__SKILL_NAME__` has no arguments, check every joined team's inbox
immediately:

```bash
~/.agents/skills/__SKILL_NAME__/scripts/inbox.sh <team> <agent>
```

If messages arrive, act on them and reply with:

```bash
~/.agents/skills/__SKILL_NAME__/scripts/send.sh <team> <agent> <recipient> "<message>"
```

Other commands:

- `/__SKILL_NAME__ team`:
  `team.sh <team>`
- `/__SKILL_NAME__ history`:
  `history.sh <team> <agent>`
- `/__SKILL_NAME__ send <recipient> <message>`:
  resolve the recipient's team and run `send.sh`
- `/__SKILL_NAME__ mode`:
  `delivery.sh status qwen "$(pwd)"`
- `/__SKILL_NAME__ mode turn|off`:
  `delivery.sh set <mode> qwen "$(pwd)"`
- `/__SKILL_NAME__ version`:
  `version.sh`
- `/__SKILL_NAME__ reset`:
  `reset.sh "$(pwd)" qwen`

### actas

For `/__SKILL_NAME__ actas <name>`:

1. Run `identities.sh "$(pwd)" qwen`.
2. If the role is not registered, join it to the current team with `join.sh`.
3. Use `<name>` as the sender for subsequent messages in this session.
4. Tell the user which role is active.

For `/__SKILL_NAME__ drop <name>`, run:

```bash
~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" qwen <name>
```

### spawn

For `/__SKILL_NAME__ spawn <type> <name> [options]`, run:

```bash
~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]
```

When spawning Qwen, put the task in `--boot-prompt`. Qwen turn delivery does
not wake an already-idle TUI merely because a later message arrived.

Example:

```text
/__SKILL_NAME__ spawn qwen qwen-tui --boot-prompt "Inspect the issue, then send
claude-desktop a concise report through agmsg. Stop after reporting."
```

## Working protocol

- Claude Code is a good coordinator because its monitor can receive while idle.
- Give Qwen bounded work with explicit ownership and a stop condition.
- Send summaries, file paths, commit SHAs, and test results rather than large
  raw artifacts.
- Never send credentials or Token Plan details through agmsg.
- If Qwen reports quota exhaustion, do not retry in a loop. Report the reset
  timestamp and preserve the task for one retry after that time.
