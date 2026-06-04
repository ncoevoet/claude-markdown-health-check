# Skill Usage Metrics — Phase 7

Mines `~/.claude/projects/*/<uuid>.jsonl` and `~/.claude.json#skillUsage` across a 30-day window for per-skill invocation, dormancy, and orphan signals. Runs at Standard + Deep depth.

## Source

`scan-history.sh` writes `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/history-scan.json`. Sections used:

- `.skillLedger[<name>]` → `{usageCount, lastUsedAt}` from `~/.claude.json#skillUsage` — **the authoritative per-machine cumulative usage signal**. It counts every activation path (direct `Skill` tool call, `/slash` command, AND subagent dispatch); `scan-history.sh` folds `agents:<name>` entries into the bare `<name>`, so a skill invoked only as a subagent (e.g. `code-review-agent`) still shows its true count here. Absence from `.skillLedger` (or `usageCount==0`) is the only reliable "never fired on this machine" signal.
- `.skills[<name>]` → `{invokes, sessions, last_ts}` (in-window `tool_use{name="Skill"}` from transcripts). This is a **recency/session detail layer only** — it misses subagent and slash invocations, so it MUST NOT be used alone to decide "never fired".
- `.meta.window_days`.

## Variables (per skill `s`)

- `ledgerCount(s)` = `.skillLedger[s].usageCount // 0` — authoritative cumulative count (see Source).
- `invokes(s)` = `.skills[s].invokes // 0` — in-window transcript count (recency detail only).
- `everFired(s)` = `ledgerCount(s) > 0 OR invokes(s) > 0` — has this skill EVER run on this machine?
- `lastUsed(s)` = `max(.skills[s].last_ts, .skillLedger[s].lastUsedAt/1000)` → days-since.
- `firedInWindow(s)` = `invokes(s) > 0 OR days_since(lastUsed(s)) <= WINDOW_DAYS`.
- `cost(s)` = combined `description + when_to_use` char count from Phase 5 (`validate-skills.sh --listing-cost`).
- `sessions(s)` = `.skills[s].sessions // 0`.

## Tags

The ledger is authoritative: `everFired(s)` distinguishes a skill that has *never* run from one that ran historically but has gone quiet. Do NOT flag a skill `SKILL-NEVER-FIRED` when `ledgerCount(s) > 0` — that is the `code-review-agent`-via-subagent false positive this phase exists to avoid.

| Tag | Condition | Tier |
|---|---|---|
| `SKILL-NEVER-FIRED` | `NOT everFired(s)` (i.e. `ledgerCount==0 AND invokes==0`) | Structural |
| `SKILL-DORMANT` | `everFired(s) AND NOT firedInWindow(s)` | **Critical** when also `cost > 3000`; else Structural |
| `SKILL-MISFIRING` | `invokes>=5 AND sessions(s)/invokes(s) < 0.20` (loaded but never followed through; same skill repeatedly opened in one session is a poor-trigger signal) | Structural |
| `SKILL-ORPHAN` | `ledgerCount(s) > 0` AND no SKILL.md found in `~/.claude/skills/` or project tree AND skill not in `enabledPlugins` bundled list | Critical |

`SKILL-MISFIRING` heuristic uses `sessions/invokes` rather than the planned `engagement_ratio` because telemetry-side load counters are not available locally — multiple invokes in the same session implies the skill body was loaded but the model kept re-loading it, a weaker but observable misfire signal.

## Report block (above tier list)

```
### Skill Usage (last 30d)
Invoked: X · Dormant: Y · Never-fired: Z · Misfiring: W · Orphan: V
Top-fired: <skill>(N), <skill>(N), …
```

`Invoked` = `firedInWindow`, `Dormant` = `everFired AND NOT firedInWindow`, `Never-fired` = `NOT everFired` — all derived from `ledgerCount` first, transcripts second. `Top-fired` ranks by `ledgerCount(s)` (cumulative), not in-window `invokes`, so heavily-used subagent skills surface correctly.

## Remediation order

1. `SKILL-ORPHAN` → reinstall the plugin or remove the stale `skillUsage` entry.
2. `SKILL-DORMANT` (Critical) → trim description, disable per-project via `skillOverrides`, or remove from `enabledPlugins`.
3. `SKILL-NEVER-FIRED` → name-only (clear description) or disable via `/skills`.
4. `SKILL-MISFIRING` → rewrite description / when_to_use to be more specific, then re-evaluate after a week.

## Privacy

Findings reference skill names only. Session paths are stripped by `scan-history.sh` before caching. Wording must use "in this install" — usage on other machines is invisible.
