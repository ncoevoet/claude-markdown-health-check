# Auto-memory Hygiene — Phase 20

Audits the link-index format of every `~/.claude/projects/*/memory/MEMORY.md`. Runs at Standard + Deep depth. Freeform MEMORY.md files (no `- [Title](file.md)` link entries) are left alone.

## Source

`scan-graph.sh` writes `graph-scan.json`. Filter on `.phase == 20`.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `MEMORY-DEAD-LINK` | linked `file.md` missing in the same memory directory | Critical |
| `MEMORY-ORPHAN-FILE` | `.md` in memory dir (other than `MEMORY.md`) with no matching `- [.](file.md)` line | Hygiene |
| `MEMORY-DUP-ENTRY` | same `file.md` linked from two different lines in `MEMORY.md` | Hygiene |
| `MEMORY-STALE-DATE` | a date string `YYYY-MM-DD` inside MEMORY.md is older than `MEMORY_STALE_DAYS` (env, default 365) | Hygiene |

## Report block

```
### Auto-memory
Indexes: N · Dead links: X · Orphans: Y · Dups: Z · Stale dates: W
```
Emit nothing when all four are 0.

## Remediation order

1. `MEMORY-DEAD-LINK` (Critical) → either restore the file or remove the link.
2. `MEMORY-DUP-ENTRY` → keep one line, delete the duplicate.
3. `MEMORY-ORPHAN-FILE` → add a `- [Title](file.md) — hook` line to MEMORY.md or delete the file.
4. `MEMORY-STALE-DATE` → review whether the entry is still relevant; rewrite or delete.
