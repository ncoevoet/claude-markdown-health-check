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
| `MCP-DEPRECATED-TRANSPORT` | an `mcpServers` entry of `"type":"sse"` in `.mcp.json` (project root or `$CLAUDE_DIR/`), `~/.claude.json`, or a settings file — the SSE transport is deprecated in favour of `http`/`streamable-http` | Hygiene |
| `PLUGIN-MISPLACED-DIR` | a component dir (`skills`/`agents`/`commands`/`hooks`/`output-styles`/`monitors`) nested inside `.claude-plugin/` — components must sit at the plugin root | Critical |
| `PLUGIN-BAD-VERSION` | `plugin.json` has no `version`, or a non-semver one — Claude Code then falls back to the git SHA and treats every commit as a new version | Structural |
| `PLUGIN-ABS-PATH` | a declared component path (`skills`/`commands`/`agents`/`outputStyles`/`lspServers`) is not relative starting with `./` | Structural |
| `MARKETPLACE-DEAD-SOURCE` | a `.claude-plugin/marketplace.json` plugin `source` (a local-path *string*; object/remote sources are skipped) resolves to no directory. Resolution honours `metadata.pluginRoot`, so a bare `"source": "formatter"` under `pluginRoot: "./plugins"` resolves to `plugins/formatter/` | Critical |

The plugin-root checks fire only when `CLAUDE_DIR` contains `.claude-plugin/plugin.json` — i.e. when the scanner is pointed at a plugin repo (development / dogfooding), not a normal `~/.claude` tree.

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
