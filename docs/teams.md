# Team operations

The [README](../README.md) covers the slash-command flow most users need. This page collects the rest: identity model, joining the same team from a second project, multi-name workspaces, and clearing or resetting registrations.

You don't need to call shell scripts to do any of this. Talk to your agent or use the slash-command forms below.

## How identity works

Agents join teams by **identity**: `(agent name, team)`. Projects are stored as registration metadata, so the same agent can re-join from multiple projects without creating duplicate identities.

This is what makes "same agent on two laptops / two repos" work without forking your inbox. Messages addressed to `alice` reach whichever live session is registered as `alice`, regardless of which project that session is in.

## Joining a team

In your project:

```
/agmsg
```

On first use it prompts for a team name (joins existing or creates new) and an agent name. That's the whole onboarding.

## Joining the same team from a second project

Open the second project in your agent and run `/agmsg`. When it asks for the agent name, give the same name you used before. agmsg recognizes the existing identity and registers the new project against it — your inbox stays unified.

## Multiple agent names on one project

You can register more than one name in the same project (e.g. `cc` and `reviewer`). Run `/agmsg` and answer with each name in turn. After the second join, `/agmsg` detects multiple identities on this project and asks which one to use for the current session.

For the case where one workspace plays multiple *roles* (e.g. a `tech-lead` identity and a `biz-analyst` identity sharing the same checkout), use `actas` instead:

```
/agmsg actas tech-lead
/agmsg actas biz-analyst
/agmsg drop biz-analyst
```

`actas` is the right tool when the roles are mutually exclusive across sessions — see [docs/actas.md](actas.md).

## Clearing a project's registrations

```
/agmsg reset
```

Removes the current project's registrations without leaving the team identity entirely. Useful before moving the project or starting a clean rejoin. Other projects' registrations of the same identity are untouched.

To remove a single role:

```
/agmsg drop <name>
```

## Leaving a team entirely

There's no slash-command shortcut for "leave team X across all projects". Ask your agent to leave — it knows the script (`leave.sh <team> <agent>`) and will run it for you. All registrations across all projects for that `(team, agent)` pair are removed; messages already in the DB stay.

## Renaming a team

Same idea: ask your agent to rename the team. It will move the team directory, update the config, and migrate the messages. Existing members keep their registrations and history under the new name. Any already-running session keeps the old cached name until it re-resolves identity — running `/agmsg` again is enough to pick up the new name.

## See also

- [docs/actas.md](actas.md) — multi-role mechanics, exclusivity locks, Codex caveat.
- [README — Shell (any agent)](../README.md#shell-any-agent) — script quick-reference for automation, CI, sandboxes.
