# Cross-Session Pattern Mining — Phase 19 (also drives Phase 22)

Pulls recurring signals from `history-scan.json`. Runs at Deep depth only.

## Source

`history-scan.json` sections:
- `.denials.count` → aggregate denial count.
- `.corrections` → array of `{session, text}` matching `^(no|nope|not that|wait|stop|always|never)\b`.
- `.agentSpawns[<subagent>]` → `{count, sessions}`.

## Tags (phase 19)

| Tag | Condition | Tier |
|---|---|---|
| `RECURRING-DENIAL` | `.denials.count >= 5` over window (no per-tool breakdown available — coarse aggregate only) | Structural |
| `HOOK-FAILING` | reported by Phase 16 — Phase 19 does NOT re-flag | — |
| `RECURRING-CORRECTION` | cluster of ≥3 correction `text` values with shared 3-word prefix (case-insensitive), spanning ≥2 sessions | Hygiene |
| `MISSING-SKILL-GAP` | `.agentSpawns[X].sessions >= 5` AND no installed skill matches `X` by name OR description keyword Jaccard ≥0.4 | Critical |

## Tags (phase 22 — Agent Never-Spawned)

| Tag | Condition | Tier |
|---|---|---|
| `AGENT-NEVER-SPAWNED` | agent file at `~/.claude/agents/<name>.md` AND `.agentSpawns[<name>]` absent or `.count == 0` | Structural |

## Report block

```
### Cross-session patterns (last 30d)
Denials: N · Correction clusters: P · Skill gaps: Q · Idle agents: R
```

## Correction clustering

1. Lowercase each `.text`, strip non-word chars, take first 30 chars.
2. Group by the leading 3-word prefix.
3. A cluster qualifies when `count >= 3 AND distinct sessions >= 2`.

## Skill-gap matching

Iterate `.agentSpawns` entries with `count >= 5`:
- Check `agents:<name>` / `<name>` against the installed-skill name list.
- If no name match, extract 4+ char keywords from the subagent's description (when available from the agent file) and compare to each skill's description keyword set via Jaccard.
- Match threshold: Jaccard ≥ 0.4.

## Remediation order

1. `MISSING-SKILL-GAP` → propose creating a skill that captures the workflow being repeated by ad-hoc agent spawns.
2. `RECURRING-DENIAL` → review which tool keeps being asked; add to allowlist if safe.
3. `RECURRING-CORRECTION` → encode the correction as a `NEW-RULE` (see Phase 4 for the canonical tag) or add it to the relevant SKILL.md.
4. `AGENT-NEVER-SPAWNED` → remove the unused agent or document its trigger so it surfaces.
