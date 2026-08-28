# Qwen Code

Qwen Code can join an agmsg team as a terminal peer. A useful first topology is
to keep Claude Code as the always-listening coordinator and start Qwen for
bounded implementation or research tasks.

## Before connecting it to agmsg

Start Qwen once on its own so authentication, the selected model, and the
approval policy are understood independently of messaging:

```powershell
cd C:\path\to\your\project
qwen
```

In the Qwen TUI:

1. Run `/auth`, select Alibaba ModelStudio, and select the plan attached to
   your account.
2. Run `/model` and confirm the intended model.
3. Run `/approval-mode default` for normal interactive use.
4. Give it a read-only orientation task:

   ```text
   Do not change files. Explain this repository's structure, main features,
   and test commands.
   ```

Use `/plan` before a larger change, `/diff` before accepting edits,
`/compress` when the conversation becomes long, and `/recap` before ending
the session.

Resume the most recent session for the current project with:

```powershell
qwen -c
```

## Join an agmsg team

After agmsg has installed its Qwen-oriented skill, start Qwen in the project and
invoke:

```text
/agmsg
```

On first use:

1. Join the existing team or create a new one.
2. Choose a distinct role name such as `qwen-tui`.
3. Use `turn` delivery for the initial integration.

Useful commands:

```text
/agmsg
/agmsg team
/agmsg history
/agmsg send claude-desktop <message>
/agmsg mode turn
```

On Windows, agmsg scripts must use Git Bash, not the WindowsApps WSL `bash`
shim. A typical path is `C:\Program Files\Git\bin\bash.exe`.

## Start Qwen from Claude Code

Qwen's `--prompt-interactive` / `-i` option runs an initial prompt and then
keeps the TUI open. Once the Qwen driver is installed, Claude Code can use:

```text
/agmsg spawn qwen qwen-tui --boot-prompt "Inspect the issue, do not edit files,
and send a concise report to claude-desktop over agmsg."
```

For an implementation task, make ownership and completion explicit:

```text
You own <files or responsibility>. Other agents may be working in the repository;
do not revert their changes. Implement <bounded task>, run <checks>, then send
claude-desktop a summary containing changed paths, test results, and any
remaining risk. Stop after sending the report.
```

Claude Code is the recommended coordinator because its agmsg monitor can receive
the result while idle. Qwen is initially treated as a task worker:

1. Claude starts Qwen with the task in the boot prompt.
2. Qwen works in its own terminal.
3. Qwen sends its result to Claude through agmsg.
4. Claude reviews or assigns a follow-up.

## Idle-session limitation

`turn` delivery checks messages at Qwen lifecycle hooks. It does not by itself
turn an already-idle TUI into a new model turn when a message arrives later.
Therefore, do not rely on sending the first task to an idle Qwen session.

Prefer one of these:

- include the task in `spawn --boot-prompt`;
- type a short prompt in the existing Qwen TUI to trigger the next turn;
- use ACPX for a bounded non-interactive delegation when a persistent TUI is
  unnecessary.

## Quota exhaustion

A Token Plan can reject a new run when its rolling quota is exhausted. The error
includes a reset timestamp. Treat that timestamp as the retry boundary:

- do not retry in a loop;
- preserve the task brief;
- continue token-free preparation or use another already-approved agent;
- retry once after the stated reset time.

Quota exhaustion after session creation confirms that the CLI and
authentication route were reached; it is not evidence that agmsg or the local
Qwen installation is broken.

## Safety defaults

- Keep `/approval-mode default` for ordinary work.
- Use `/plan` for read-only analysis before broad changes.
- Do not put API keys or plan credentials in an agmsg message, task brief, or
  repository file.
- Check `/diff` and run the repository's normal tests before reporting done.
- Give every cross-agent task an explicit stop condition.
