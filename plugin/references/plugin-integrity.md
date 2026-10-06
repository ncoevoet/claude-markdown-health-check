# Plugin Install Integrity — Phase 2

Validates `~/.claude/plugins/installed_plugins.json` against the on-disk plugin cache (user tree only). When the scanned tree is itself a **plugin root** (a `.claude-plugin/plugin.json` is present), it also validates that plugin's own manifest and structure — any scope — so the tool dogfoods on plugin repos. Runs at Standard + Deep depth.

## Source

`scan-graph.sh` writes `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/graph-scan.json`. Filter the findings array on `.phase == 2`.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `PLUGIN-BROKEN-REF` | `installPath` listed in `installed_plugins.json` but directory missing on disk | Critical |
| `PLUGIN-MISSING-MANIFEST` | install dir exists but contains no `plugin.json` | Critical |
| `PLUGIN-VERSION-DRIFT` | `installed_plugins.json#plugins[].version` differs from on-disk `plugin.json#version` (versions of "unknown" are ignored) | Structural |
| `PLUGIN-DISABLED` | a plugin installed at user scope (`installed_plugins.json`) but absent from `settings.json#enabledPlugins` — parked on disk, loaded by nothing. Skipped entirely when no `enabledPlugins` map exists, so enable-state stays indeterminate rather than false-flagged; a manifest setting `defaultEnabled: false` ships parked by design and is exempt | Hygiene |
| `PLUGIN-MISSING-DEPENDENCY` | an installed plugin's `plugin.json#dependencies` names a plugin (string entry or `{name, version}`) absent from `installed_plugins.json`. Presence only — version constraints are not evaluated | Structural |
| `MARKETPLACE-BLOCKED` | an installed plugin whose marketplace (the `@…` half of the install key) is listed in `settings.json#blockedMarketplaces`, or — with `strictKnownMarketplaces: true` — appears in neither `plugins/known_marketplaces.json` nor `extraKnownMarketplaces`. The plugin stays on disk and never loads | Critical |
| `MCP-DEPRECATED-TRANSPORT` | an `mcpServers` entry of `"type":"sse"` in a location Claude Code loads (repo-root `.mcp.json`, `~/.claude.json`, a plugin's `.mcp.json`) — the SSE transport is deprecated in favour of `http`/`streamable-http` | Hygiene |
| `MCP-BAD-DEF` | an `mcpServers` entry declaring neither a `command` (stdio) nor a `url` (http/sse) — the server has no way to start. Checked only in the locations Claude Code loads (as for `MCP-DEPRECATED-TRANSPORT`) | Structural |
| `MCP-PLAINTEXT-SECRET` | an `mcpServers` entry whose `env` or `headers` carries a hardcoded credential (same credential patterns as `EMBEDDED-SECRET`); `${VAR}`/`<your-…>`/`example` placeholders are skipped, so `"Authorization": "Bearer ${TOKEN}"` is clean. Checked only in the locations Claude Code loads (as for `MCP-DEPRECATED-TRANSPORT`) | Hygiene |
| `MCP-MISPLACED` | an MCP config Claude Code never reads: a `.mcp.json` inside `.claude/` (not a plugin root), a project-root `.mcp.json` whose servers sit under a top-level `servers` key instead of `mcpServers`, or an `mcpServers` key in `settings.json`/`settings.local.json`. Entries in these misplaced files are reported once, as `MCP-MISPLACED` — never also as `MCP-DEPRECATED-TRANSPORT`, `MCP-BAD-DEF` or `MCP-PLAINTEXT-SECRET` | Critical |
| `MCP-RELATIVE-PATH` | an `mcpServers` `command`/`args` that is a relative path (`./x`, `../x`, `dir/x`) in `.mcp.json` or `~/.claude.json` (top level and `projects.<path>`): it resolves against the directory Claude Code was launched from, not against the config file. `npx`/`uvx`/absolute paths are fine | Hygiene |
| `PLUGIN-MISPLACED-DIR` | a component dir (`skills`/`agents`/`commands`/`hooks`/`output-styles`/`monitors`/`workflows`/`themes`/`bin`) nested inside `.claude-plugin/` — components must sit at the plugin root | Critical |
| `PLUGIN-BAD-VERSION` | `plugin.json` has no `version`, or a non-semver one — Claude Code then falls back to the git SHA and treats every commit as a new version | Structural |
| `PLUGIN-ABS-PATH` | a declared component path (`skills`/`commands`/`agents`/`outputStyles`/`lspServers`/`workflows`/`hooks`/`mcpServers`/`experimental.themes`/`experimental.monitors`) is not relative starting with `./`. Only paths that stay inside the plugin root are covered: a path that leaves it (`../x`, an absolute path outside the root) is reported solely as `PLUGIN-PATH-ESCAPE`. `skills: "."` is the one documented exception and is exempt; inline object values for `hooks`/`mcpServers`/`lspServers` are configuration, not paths, and are skipped | Structural |
| `PLUGIN-USERCONFIG-IN-SHELL` | a hook `command` (inline in `plugin.json` or in `hooks/hooks.json`) or a monitor `command` (`monitors/monitors.json`, `experimental.monitors`) interpolates `${user_config.…}`. Claude Code rejects that substitution in shell commands — it is supported only in skill/agent bodies and in MCP/LSP `env` | Structural |
| `PLUGIN-RESERVED-NAME` | `plugin.json#name` or a `marketplace.json#plugins[].name` passes as one of Anthropic's own, after lower-casing and collapsing separator runs (edge hyphens are not trimmed): prefix `claude-`/`anthropic-`/`anthropics-`/`cc-plugin-`, exactly `claude`/`anthropic`/`anthropics`/`claude-code`/`claude-mods`, or `official` beside `claude`/`anthropic`. `claude plugin init/tag` refuse it; Claude Code still installs it. `myofficial-claude` is deliberately not flagged | Structural |
| `PLUGIN-NAME-LOOKALIKE` | `claude`/`anthropic`/`anthropics` as a whole word elsewhere in a plugin name (`mcp-for-claude`) — the validator's Warning row | Hygiene |
| `PLUGIN-NAME-FORMAT` | a plugin name (or marketplace entry name) that is empty, or contains whitespace, `@`, `:`, `/`, `\`, a control character or a bidirectional-formatting character (matched by jq, no `grep -P`); a leading `-` is flagged as a heuristic (not in the docs: `claude plugin install` would read it as an option); a marketplace entry must also fit the plugin-id alphabet | Structural |
| `PLUGIN-NAME-NOT-KEBAB` | a valid plugin name that is not lower-case kebab-case (`^[a-z0-9]+(-[a-z0-9]+)*$`) | Hygiene |
| `MARKETPLACE-NAME-FORMAT` | marketplace `name` empty, outside letters/digits/`.`/`_`/`-`, not starting alphanumeric, containing `..`, or holding a control/bidi character — nothing can be installed from it | Critical |
| `MARKETPLACE-NAME-RESERVED` | marketplace `name` on the reserved list (any casing), another spelling of one, `claudeai-` prefixed, non-ASCII, `official` beside claude/anthropic, or `^(claude\|anthropic)-plugins?(-\|$)`. The `github.com/anthropics/` exemption is not evaluated: dismiss the finding if the marketplace is hosted there | Critical |
| `MARKETPLACE-DEAD-SOURCE` | a `.claude-plugin/marketplace.json` plugin `source` (a local-path *string*; object sources and the remote string forms `http…`, `git@…`, `npm:…`, `github:…`, `git:…` are skipped) resolves to no directory. Resolution honours `metadata.pluginRoot`, so a bare `"source": "formatter"` under `pluginRoot: "./plugins"` resolves to `plugins/formatter/` | Critical |
| `PLUGIN-DEFAULT-DIR-SHADOWED` | `plugin.json` sets a key that **replaces** its default folder (`commands`, `agents`, `outputStyles`, `workflows`, `experimental.themes`, `experimental.monitors`) while that folder (`commands/`, `agents/`, `output-styles/`, `workflows/`, `themes/`, `monitors/`) exists and none of the key's paths is the folder or a path inside it. Claude Code then shows `Default <folder>/ folder is ignored because the manifest sets "<key>"`. `skills` (adds to the default) and `hooks`/`mcpServers`/`lspServers` (merge) are never flagged; listing the folder explicitly (`"commands": ["./commands/", "./extras/"]`) is the fix | Hygiene |
| `PLUGIN-UNKNOWN-KEY` | an unrecognised top-level `plugin.json` key. Claude Code strips it and the plugin loads (`claude plugin validate` warns). The message adds a did-you-mean when the key matches a documented one after lower-casing and dropping `_`/`-`. Deprecated top-level `themes`/`monitors` still load and are not flagged | Hygiene |
| `PLUGIN-STRICT-OBJECT-UNKNOWN-KEY` | an unknown key inside an inline `userConfig` option (also the options of a `channels` entry), a `channels` entry, an `lspServers` config or an `experimental.monitors` entry. These objects are strict: the plugin does not load. A `.json` file named by `lspServers` or `mcpServers` is not read | Critical |
| `PLUGIN-PATH-ESCAPE` | a component path (`skills`/`commands`/`agents`/`outputStyles`/`workflows`/`hooks`/`mcpServers`/`lspServers`/`experimental.*`, string entries and `commands` map `source`) whose lexical normalisation leaves the plugin root (`../x`, `./a/../../x`), or an absolute path outside it. Claude Code refuses to load it (`path escapes plugin directory`). A `..` that stays inside the root loads and is not flagged; `Path not found` (a path that does not exist) is out of scope | Critical |
| `MARKETPLACE-UNKNOWN-KEY` | an unknown top-level or plugin-entry key in `marketplace.json`. Claude Code ignores it, so a typo (`ownr`, `sorce`) loads silently. `metadata` and an entry's `relevance` are free objects; an entry accepts every `plugin.json` field except the directory-listing ones (`icon`, `documentationUrl`, `supportUrl`, `privacyPolicyUrl`, `termsOfServiceUrl`) | Hygiene |
| `EVAL-CASE-NO-GRADER` | a plugin eval case (a directory holding `prompt.md` or `case.yaml`; outermost only; `results/` and `mocks/` skipped) has neither `graders/*.md` nor a non-empty top-level `graders:` list in `case.yaml` — `claude plugin eval` fails to load it. The eval dir is `experimental.evals` (first entry of an array, plain relative name) else `evals/` | Structural |
| `EVAL-NO-SKILL-GRADER` | the suite has at least one case, yet no grader file with `type: tool_used` and `tool: Skill` names a model-invocable skill (no `disable-model-invocation: true`). Skills are counted under `skills/` plus every manifest `skills` entry (`"."` is the plugin root; `..`/absolute entries ignored). `case.yaml` graders are matched file-wide, a coarse check | Hygiene |
| `PLUGIN-NO-EVALS` | the plugin ships a model-invocable skill and its eval dir holds no case (an `evals/` with only another tool's JSON counts as no suite). Evals are in early access, so this is a discovery nudge, never a defect; commands are not counted as skills | Discovery |

The plugin-root checks fire only when `CLAUDE_DIR` contains `.claude-plugin/plugin.json`, or (for the plugin and marketplace name checks) a `.claude-plugin/marketplace.json` — i.e. when the scanner is pointed at a plugin repo (development / dogfooding), not a normal `~/.claude` tree.

## Report block (above tier list)

```
### Plugin Integrity
Plugins: N installed | Broken: X | Missing manifest: Y | Drift: Z
```
Emit nothing when X=Y=Z=0.

## Remediation order

1. `PLUGIN-BROKEN-REF` → run `/plugin install <name>` or remove the orphan entry from `installed_plugins.json`.
2. `PLUGIN-MISSING-MANIFEST` → reinstall the plugin (most likely a corrupted cache).
3. `PLUGIN-VERSION-DRIFT` → `/plugin update <name>` to sync, then accept the new manifest.
4. `MCP-DEPRECATED-TRANSPORT` → change the server's `"type"` from `"sse"` to `"http"` (alias `"streamable-http"`) where the server supports it.
5. `MCP-BAD-DEF` → add a `command` (for a stdio server) or a `url` (for an http/sse server); an entry with neither never loads.
6. `MCP-PLAINTEXT-SECRET` → move the literal token to an environment variable and reference it with `${ENV_VAR}` interpolation in `env`/`headers`.
7. `MARKETPLACE-BLOCKED` → unblock the marketplace, add it to `extraKnownMarketplaces`, or uninstall the plugin — it is dead weight until one of those happens.
8. `PLUGIN-MISSING-DEPENDENCY` → `/plugin install <dependency>`, or drop the entry if the plugin no longer needs it.
9. `PLUGIN-USERCONFIG-IN-SHELL` → read the value from `CLAUDE_PLUGIN_OPTION_<KEY>` in the script, or move the command to the exec form and pass the value through `args`.
10. `PLUGIN-DISABLED` → `/plugin uninstall <name>` to reclaim disk if the plugin is unused, or `/plugin enable <name>` if it was parked by mistake. Intentionally-disabled plugins are a legitimate state — this is a polish-tier nudge, not a defect.
11. `MCP-MISPLACED` → move the servers into a project-root `.mcp.json` (under `mcpServers`), or into the plugin's own `.mcp.json`; Claude Code never reads the misplaced file.
12. `PLUGIN-RESERVED-NAME` → rename the plugin; names that pass as Anthropic's own are reserved.
13. `PLUGIN-NAME-FORMAT` → rename the plugin to lower-case letters, digits and hyphens, with no spaces, `@`, `:`, path separators or control characters.
14. `MARKETPLACE-NAME-FORMAT` → rename the marketplace (letters, digits, `.`, `_`, `-`; start alphanumeric; no `..`), then update every `plugin@marketplace` reference.
15. `MARKETPLACE-NAME-RESERVED` → rename the marketplace off the reserved list, then update every `plugin@marketplace` reference.
16. `EVAL-CASE-NO-GRADER` → add a `graders/*.md` file or a non-empty `graders:` list in `case.yaml` to the case; `claude plugin eval` cannot load it otherwise.

## Refreshing the manifest key sets

The key sets live in ONE place, the `PJ_KEYS`, `UC_KEYS`, `CH_KEYS`, `LSP_KEYS`, `MON_KEYS`, `MP_KEYS` and `ENTRY_KEYS` variables of `scan_plugin_manifest_keys` in `scan-graph.sh`, each commented with the doc sentence it came from. They are not copied here. To refresh one, list the first column of the matching table, for example the `plugin.json` fields:

```
curl -s https://code.claude.com/docs/en/plugins/manifest-reference.md | awk -F'|' '/^## Fields/{f=1} /^### `name`/{f=0} f && /^\| *(\[)?`/ {gsub(/[ `\[]/,"",$2); sub(/\].*/,"",$2); print $2}'
```

For the `userConfig`, `Channels`, `lspServers` and `monitors` tables, run the same awk between that section's heading and the next one. A `PLUGIN-UNKNOWN-KEY` on `plugin/` or on a fixture means the array is incomplete: fix the array, not the manifest.
