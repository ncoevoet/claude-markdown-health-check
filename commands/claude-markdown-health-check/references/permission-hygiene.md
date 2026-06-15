# Permission Allowlist Hygiene — Phase 15

Cross-references `settings.json#permissions.allow` against the cross-session denial count from `history-scan.json`. Runs at Standard + Deep depth.

## Source

- `~/.claude/settings.json` + `settings.local.json` — `.permissions.allow` arrays.
- `history-scan.json` → `.denials.count` (total cross-session tool denials in window — exact tool name is NOT captured because the JSONL `tool_result` text doesn't carry it reliably).

Because the per-tool denial breakdown is unavailable, Phase 15 only emits the coarser tags below. The `PERM-MISSING-ENTRY` heuristic (denied ≥5×) cannot fire and is parked.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `PERM-DEAD-ENTRY` | best-effort: allowlist entry whose tool name does not appear in any `tool_use` invocation in the window | Hygiene |
| `PERM-OVERBROAD` | entry uses `:*` AND its prefix matches fewer than 3 distinct in-window tool-use names | Hygiene |
| `PERM-MISSING-ENTRY` | parked until per-tool denial data is reachable | — |
| `SETTINGS-BYPASS-MODE` | `defaultMode` (or `permissions.defaultMode`) == `"bypassPermissions"` — every tool call is auto-approved with no prompt (relayed from `validate-skills.sh`) | Critical |
| `SETTINGS-MCP-AUTOAPPROVE` | `enableAllProjectMcpServers` == `true` — every project `.mcp.json` server is trusted without review (relayed from `validate-skills.sh`) | Hygiene |

To compute `PERM-DEAD-ENTRY`: extract each entry's tool name (prefix before `(`), and check it against `history-scan.json` → `.toolCalls` keys. Entries with no matching key are dead.

## Report block

```
### Permission Hygiene
Allow: N entries · Dead: X · Overbroad: Y · Total denials: Z
```

## Remediation order

1. `SETTINGS-BYPASS-MODE` → drop `bypassPermissions`; use `acceptEdits` or default mode, or set `disableBypassPermissionsMode` in managed settings.
2. `SETTINGS-MCP-AUTOAPPROVE` → set `enableAllProjectMcpServers` to false and allow-list specific servers via `enabledMcpjsonServers`.
3. `PERM-OVERBROAD` → tighten the matcher pattern (e.g., `Bash(cat:*)` → `Bash(cat ~/.claude/*)`).
4. `PERM-DEAD-ENTRY` → delete entries whose tool was never invoked in 30 days.
5. Review the raw `Total denials` count via the user's session log if it seems high — may indicate a missing allowlist entry.
