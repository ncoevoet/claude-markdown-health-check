# Skill Usage Metrics — Phase 7

Mines `~/.claude/projects/*/<uuid>.jsonl` and `~/.claude.json#skillUsage` across a 30-day window for per-skill invocation, dormancy, and orphan signals. Runs at Standard + Deep depth.

## Source

`scan-history.sh` writes `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/history-scan.json`. Sections used:

- `.skillLedger[<name>]` → `{usageCount, lastUsedAt}` from `~/.claude.json#skillUsage` — authoritative per-machine cumulative signal; counts every activation path (Skill tool, `/slash`, subagent dispatch). Folds `agents:<name>` into `<name>`, so a subagent-only skill (e.g. `code-review-agent`) still shows its true count. Absence (or `usageCount==0`) is the only reliable "never fired" signal.
- `.skills[<name>]` → `{invokes, sessions, last_ts}` (in-window `tool_use{name="Skill"}` events) — recency/session detail only; misses subagent and slash invocations, so MUST NOT be used alone to decide "never fired".
- `.observedRecall[<name>]` → `{triggers, misses}` — anchor-bearing prompts (`anchor_hit`, `--anchors-file`) joined against `.skills[<name>]` fire events within a 300s window. Skill names/timestamps only, never prompt text (see Privacy). **The join only counts artifact-shaped anchor tokens** — a leading-dot extension (`.logx`), a dotted filename (`pom.xml`), or a multi-word backticked literal (`ng build`) — never a bare proper noun, acronym, or hyphenated identifier (`claude`, `ci`, `threat-model`). `validate-skills.sh --anchors` still emits its full five-class set unfiltered (`NO-UNIQUE-ANCHOR`/`ANCHOR-COLLISION`/`SKILL-DUPLICATE-DOMAIN` need it whole); the filter is applied in `scan-history.sh` (`is_artifact_shaped`), the consumer, because a bare word is discussion, not invocation intent — measured on a real install, "claude" alone appeared in >50% of prompts, which made this tag fire on almost every skill until the restriction was added.
- `.meta.window_days`.

## Variables (per skill `s`)

- `ledgerCount(s)` = `.skillLedger[s].usageCount // 0` — authoritative cumulative count.
- `invokes(s)` = `.skills[s].invokes // 0` — in-window count (recency only).
- `everFired(s)` = `ledgerCount(s) > 0 OR invokes(s) > 0` — ever ran on this machine?
- `lastUsed(s)` = `max(.skills[s].last_ts, .skillLedger[s].lastUsedAt/1000)` → days-since.
- `firedInWindow(s)` = `invokes(s) > 0 OR days_since(lastUsed(s)) <= WINDOW_DAYS`.
- `cost(s)` = combined `description + when_to_use` char count (`validate-skills.sh --listing-cost`, Phase 5).
- `sessions(s)` = `.skills[s].sessions // 0`.
- `triggers(s)` = `.observedRecall[s].triggers // 0` — anchor hits followed by a fire within 300s.
- `misses(s)` = `.observedRecall[s].misses // 0` — anchor hits with no fire in that window.

## Tags

`everFired(s)` separates never-ran from ran-but-quiet. Do NOT flag `SKILL-NEVER-FIRED` when `ledgerCount(s) > 0` — that's the `code-review-agent`-via-subagent false positive this phase exists to avoid.

| Tag | Condition | Tier |
|---|---|---|
| `SKILL-NEVER-FIRED` | `NOT everFired(s)` (i.e. `ledgerCount==0 AND invokes==0`) | Structural |
| `SKILL-DORMANT` | `everFired(s) AND NOT firedInWindow(s)` | **Critical** when also `cost > 3000`; else Structural |
| `SKILL-MISFIRING` | `invokes>=5 AND sessions(s)/invokes(s) < 0.20` (loaded but never followed through; same skill repeatedly opened in one session is a poor-trigger signal) | Structural |
| `SKILL-ORPHAN` | `ledgerCount(s) > 0` AND no SKILL.md found in `~/.claude/skills/` or project tree AND skill not in `enabledPlugins` bundled list | Critical |
| `SKILL-LOW-OBSERVED-RECALL` | `misses(s) >= 3 AND triggers(s)/(triggers(s)+misses(s)) < 0.5` | Structural |

Skills with `disable-model-invocation: true` load nothing per session, firing only via `/name`. Don't emit `SKILL-NEVER-FIRED`/`SKILL-DORMANT` for them — an unused manual command costs nothing; note as an observation at most.

`SKILL-MISFIRING` uses `sessions/invokes`, not the planned `engagement_ratio` — load-counter telemetry isn't available locally; repeated same-session invokes (body reloaded, no follow-through) is a weaker but observable misfire signal.

`SKILL-LOW-OBSERVED-RECALL` joins `anchor_hit` against `skill` fires on `(session, skill)` within a **300s window** — a proxy ("should have fired right after this prompt"), same heuristic class as `SKILL-MISFIRING`. No turn index exists, so a miss outside 300s is invisible. Evidence MUST read as a count, not a verdict — a hit doesn't prove the skill should have fired (discussing a token isn't requesting the action): `4 prompts / 30d contained ".bpmn"; skill fired on 0 — in this install`. Complementary to `SKILL-MISFIRING`: misfiring is fires-too-readily-with-no-follow-through; low observed recall is anchor-present-but-never-fires. Remediation: name the missing anchor sentence (`ANCHOR-NOT-STATED`); `coder_eval` (https://github.com/UiPath/coder_eval, Apache 2.0) measures activation properly against a hand-labeled prompt set — this auditor doesn't run it.

## Report block (above tier list)

```
### Skill Usage (last 30d)
Invoked: X · Dormant: Y · Never-fired: Z · Misfiring: W · Orphan: V
Top-fired: <skill>(N), <skill>(N), …
```

`Invoked` = `firedInWindow`, `Dormant` = `everFired AND NOT firedInWindow`, `Never-fired` = `NOT everFired` — derived from `ledgerCount` first, transcripts second. `Top-fired` ranks by `ledgerCount(s)` (cumulative), not in-window `invokes`, so heavily-used subagent skills surface correctly.

## Remediation order

1. `SKILL-ORPHAN` → reinstall the plugin or remove the stale `skillUsage` entry.
2. `SKILL-DORMANT` (Critical) → trim description, disable per-project via `skillOverrides`, or remove from `enabledPlugins`.
3. `SKILL-NEVER-FIRED` → name-only (clear description) or disable via `/skills`.
4. `SKILL-MISFIRING` → rewrite description / when_to_use to be more specific, then re-evaluate after a week.
5. `SKILL-LOW-OBSERVED-RECALL` → state the missing anchor sentence (`ANCHOR-NOT-STATED`); for a real recall measurement, run `coder_eval` against a hand-labeled prompt set.

## Privacy

Findings reference skill names only. Session paths are stripped by `scan-history.sh` before caching. Wording must use "in this install" — usage on other machines is invisible.
