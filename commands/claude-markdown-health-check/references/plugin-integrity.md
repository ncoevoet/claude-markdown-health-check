# Plugin Install Integrity — Phase 2

Validates `~/.claude/plugins/installed_plugins.json` against the on-disk plugin cache. Runs at Standard + Deep depth, user tree only.

## Source

`scan-graph.sh` writes `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/graph-scan.json`. Filter the findings array on `.phase == 2`.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `PLUGIN-BROKEN-REF` | `installPath` listed in `installed_plugins.json` but directory missing on disk | Critical |
| `PLUGIN-MISSING-MANIFEST` | install dir exists but contains no `plugin.json` | Critical |
| `PLUGIN-VERSION-DRIFT` | `installed_plugins.json#plugins[].version` differs from on-disk `plugin.json#version` (versions of "unknown" are ignored) | Structural |

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
