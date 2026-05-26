# Skill Usage Metrics — Phase 7

Mines `~/.claude/projects/*/<uuid>.jsonl` and `~/.claude.json#skillUsage` across a 30-day window for per-skill invocation, dormancy, and orphan signals. Runs at Standard + Deep depth.

## Source

`scan-history.sh` writes `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/history-scan.json`. Sections used:

- `.skills[<name>]` → `{invokes, sessions, last_ts}` (in-window invocations from `tool_use{name="Skill"}`).
- `.skillLedger[<name>]` → `{usageCount, lastUsedAt}` from `~/.claude.json` (per-machine cumulative).
- `.meta.window_days`.

## Variables (per skill `s`)

- `invokes(s)` = `.skills[s].invokes // 0`.
- `lastUsed(s)` = `max(.skills[s].last_ts, .skillLedger[s].lastUsedAt/1000)` → days-since.
- `cost(s)` = combined `description + when_to_use` char count from Phase 5 (`validate-skills.sh --listing-cost`).
- `sessions(s)` = `.skills[s].sessions // 0`.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `SKILL-NEVER-FIRED` | `invokes==0 AND days_since(lastUsed) > WINDOW_DAYS` | Structural |
| `SKILL-DORMANT` | `invokes==0 AND cost > 3000` | **Critical** when both; else Structural |
| `SKILL-MISFIRING` | `invokes>=5 AND sessions(s)/invokes(s) < 0.20` (loaded but never followed through; same skill repeatedly opened in one session is a poor-trigger signal) | Structural |
| `SKILL-ORPHAN` | `skillLedger[s]` has any `usageCount` AND no SKILL.md found in `~/.claude/skills/` or project tree AND skill not in `enabledPlugins` bundled list | Critical |

`SKILL-MISFIRING` heuristic uses `sessions/invokes` rather than the planned `engagement_ratio` because telemetry-side load counters are not available locally — multiple invokes in the same session implies the skill body was loaded but the model kept re-loading it, a weaker but observable misfire signal.

## Report block (above tier list)

```
### Skill Usage (last 30d)
Invoked: X · Dormant: Y · Never-fired: Z · Misfiring: W · Orphan: V
Top-fired: <skill>(N), <skill>(N), …
```

## Remediation order

1. `SKILL-ORPHAN` → reinstall the plugin or remove the stale `skillUsage` entry.
2. `SKILL-DORMANT` (Critical) → trim description, disable per-project via `skillOverrides`, or remove from `enabledPlugins`.
3. `SKILL-NEVER-FIRED` → name-only (clear description) or disable via `/skills`.
4. `SKILL-MISFIRING` → rewrite description / when_to_use to be more specific, then re-evaluate after a week.

## Privacy

Findings reference skill names only. Session paths are stripped by `scan-history.sh` before caching. Wording must use "in this install" — usage on other machines is invisible.
