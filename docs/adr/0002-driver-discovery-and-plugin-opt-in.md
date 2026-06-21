# ADR 0002: Driver discovery, external plugin location, and opt-in trust

**Status:** accepted
**Date:** 2026-06-21
**Deciders:** @fujibee

## Context

[ADR 0001](0001-storage-driver-pluginization.md) established the 3-axis driver
model (storage, agent, delivery) and deliberately **deferred the plugin loader**
— the machinery that discovers drivers shipped outside agmsg core — until a
concrete external driver was wanted. The 1.1.0 restructure brings the agent-type
("types") axis fully into the driver layout, and that work needs a discovery
story now: where bundled drivers live, where external ones live, and how an
external driver — which is shell code run with the user's privileges — is allowed
to load without becoming a drive-by code-execution vector. This ADR makes those
decisions for all axes; it supersedes ADR 0001's deferred-loader note and its
tentative `~/.agents/agmsg/plugins/` path.

## Decision

**Bundled drivers live in-tree at `scripts/drivers/<axis>/<name>`** (the types
axis uses a directory with a `type.conf` manifest; file-based axes may use
`<name>.sh`). The agent-type tree moved from the repo root to
`scripts/drivers/types/` accordingly.

**External drivers are discovered from, in priority order:** `scripts/drivers`
(built-in), then `<install_dir>/plugins`, then each `:`-separated entry of
`$AGMSG_PLUGIN_DIRS`. Each base holds axis subdirs (`<base>/<axis>/<name>`).
Among *eligible* candidates, **later bases override earlier ones**, so an opted-in
plugin can shadow a built-in.

**External drivers are never loaded unless explicitly opted into.** A built-in
(`scripts/drivers`) is always trusted; anything under `plugins/` or
`$AGMSG_PLUGIN_DIRS` is ignored — with a clear stderr warning — until the user
runs `agmsg plugin trust <axis>/<name>`. Trust is **path-pinned**: the allowlist
records `<axis>/<name>` → absolute path, and a trusted name resolved at a
different path is not honored (a directory swap under a trusted name does not
silently activate new code). The allowlist is a TSV at `<install_dir>/db/
trusted-plugins` (preserved across `--update`, like `config.yaml`).

The opt-in CLI is `agmsg plugin list | trust <ref> | untrust <ref>`, where
`<ref>` is `<axis>/<name>` or a bare `<name>` that must be unambiguous across
axes. `driver-registry.sh` provides the axis-generic bases + trust policy;
`type-registry.sh` is the types-axis facade built on it.

`plugin.json` metadata and `min_core_version` gating (ADR 0001 §5) remain
deferred — bundled and opted-in drop-in drivers are enough for now.

## Alternatives considered

- **Auto-load any driver found on the search path (no opt-in).** Rejected: a
  malicious or accidental drop-in under `plugins/` would execute with the user's
  privileges on the next agmsg invocation. The whole point of a discovery path is
  undermined if discovery == execution.
- **Opt-in only when a plugin *overrides a built-in*; auto-load brand-new
  types.** Rejected: a brand-new external type is still arbitrary shell code. "I
  didn't put this here" is exactly the attack to defend against, override or not.
- **Trust by name only (not path).** Rejected: trusting `types/foo` once would
  then honor any future `types/foo`, so swapping the directory contents (or
  shadowing via a higher-priority base) silently activates unreviewed code.
- **External plugins at `~/.agents/agmsg/plugins/` (ADR 0001's tentative path).**
  Rejected in favor of `<install_dir>/plugins`: it sits beside the install the
  plugin extends, the `cp -R` installer never deletes it (survives `--update`),
  and per-command-name installs get their own plugin set. `~/.agents/agmsg/`
  remains the runtime/config dir (run/, config.yaml).
- **Store the allowlist in `config.yaml`.** Rejected: driver identities contain
  `/` (`types/codex`), which the YAML key parser does not handle; a flat TSV is
  simpler to append/grep/remove and sidesteps the escaping.
- **In-tree-wins (built-ins reserved, no override).** Rejected: it blocks the
  legitimate "customize a built-in type locally" use case. Later-wins among
  *trusted* candidates allows it without weakening the trust boundary.

## Consequences

- Positive: dropping a directory under `plugins/` (or pointing `AGMSG_PLUGIN_DIRS`
  at one) extends agmsg with no fork; the opt-in step keeps that from being an
  execution vector. The same machinery serves the storage and delivery axes.
- Positive: built-ins always work with zero config; the trust prompt only appears
  when an external driver is actually present.
- Negative: a new user-facing concept (`agmsg plugin trust`) and a small amount
  of registry complexity (per-axis trust gating on every resolution).
- Negative: path-pinned trust means moving a trusted plugin's directory requires
  re-trusting it. This is intentional friction.
- Neutral: `AGMSG_TYPES_ROOT` (a test-only in-tree override) is removed; the
  registry always resolves its root from the lib's own location. `AGMSG_HOME` /
  `~/.config/agmsg/types` external discovery is replaced by the scheme above.

## References

- Supersedes the deferred-loader note and `~/.agents/agmsg/plugins/` path in
  [ADR 0001](0001-storage-driver-pluginization.md)
- Specification: [`docs/spec/driver-interface.md`](../spec/driver-interface.md)
- Implements: `scripts/lib/driver-registry.sh`, `scripts/lib/type-registry.sh`,
  `scripts/plugin.sh`
