# Skill Listing Budget Audit

Loaded by `/markdown-health-check` Phase 6. Audits whether the cumulative skill-listing block fits Claude Code's runtime budget and proposes remediations.

## Why this exists

Claude Code loads every skill's `description` + `when_to_use` into one listing block at session start, capped at **1% of the context window (8,000-char floor)**; `/doctor` surfaces this as `skillListingBudgetFraction`. Over budget, descriptions drop to name-only — still invocable by name, but Claude can't auto-route to it (routing keywords gone).

Per-entry combined `description` + `when_to_use` is separately hard-capped at **1,536 characters**, enforced by `validate-skills.sh` (`DESCRIPTION-TRUNCATED`) — do NOT re-check it here.

## Compaction cap

A separate, per-skill budget applies after `/compact`: Claude Code re-attaches the most recent invocation of each skill, keeping only the **first 5,000 tokens** of each, within a combined **25,000-token** budget filled starting from the most recently invoked skill (context-window docs). `validate-skills.sh` approximates 5,000 tokens as 20,000 bytes of body (frontmatter excluded) and emits `SKILL-COMPACTION-TRUNCATED` (Hygiene) above it. Remediation: put the critical instructions at the top of the body, or move detail to `references/` files that are read on demand. The check also covers command files, which are skills.

## Compute the cost (per scope)

```bash
# Optional: set CLAUDE_CONTEXT_TOKENS=1000000 for Opus 1M sessions.
# Without it the script assumes 200000 (Sonnet/Haiku worst case).
read -r U_TOTAL U_COUNT U_BUDGET U_OVER < <(bash validate-skills.sh --listing-cost "$USER_DIR")
[[ -n "$PROJECT_DIR" ]] && read -r P_TOTAL P_COUNT P_BUDGET P_OVER < <(bash validate-skills.sh --listing-cost "$PROJECT_DIR")
GRAND_TOTAL=$(( U_TOTAL + ${P_TOTAL:-0} ))
GRAND_COUNT=$(( U_COUNT + ${P_COUNT:-0} ))
GRAND_BUDGET=${U_BUDGET}   # budget is global, not per-scope
```

Budget resolution (most specific wins): `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var → `skillListingBudgetFraction` in `<scope>/settings.json` (via `jq`) → default `0.01`. Multiply by `CLAUDE_CONTEXT_TOKENS × 4`, floor at 8,000 chars, per the docs.

The script counts user + project SKILL.md + commands, excluding any with `disable-model-invocation` truthy (`true`/`yes`/`on`/`1`) — dropped from context entirely, so they cost nothing. Plugin, marketplace and bundled skills (`/loop`, `/simplify`, `/debug`, `/claude-api`, etc.) are NOT counted. The number is a **lower bound** — say so in the report; `/doctor`'s runtime number can exceed it. Trust a visible truncation banner (`+N more`) in the latest transcript over the script-side count.

## Findings

- **`SKILL-BUDGET-OVERFLOW`** (Critical) — emit when `GRAND_TOTAL > GRAND_BUDGET`, OR an active session shows truncated descriptions. Report the numbers and top 5 cost contributors by combined `description` + `when_to_use` byte count.
- **`SKILL-LOW-RELEVANCE`** (Structural) — for each user-scope skill (skip project + plugins), grep description keywords ≥ 4 chars against the project tree (cap 500 hits). Zero hits → disable candidate. Advisory; tolerate false positives. Skip `disable-model-invocation: true` skills — nothing to reclaim.
- **`SKILL-DUPLICATE-DOMAIN`** (Structural) — Jaccard similarity ≥ 0.6, over the token set `validate-skills.sh --anchors` already produced — never derive a second keyword set from description + when_to_use. `--anchors`'s owner-count logic decides `NO-UNIQUE-ANCHOR` / `ANCHOR-COLLISION` (Phase 5); this phase reruns Jaccard ≥ 0.6 on those same tokens. Don't re-tokenize a pair that already tripped `ANCHOR-COLLISION`. Two skills covering one domain waste budget twice. Skip pairs where either sets `disable-model-invocation: true`: manual-only skills cost no budget and can't be picked by mistake, so overlap there is preference, not defect.
- **`NO-UNIQUE-ANCHOR`** (Structural) / **`ANCHOR-COLLISION`** (Structural) / **`ANCHOR-NOT-STATED`** (Hygiene) — relayed verbatim from `validate-skills.sh --anchors` (Phase 5); not recomputed, just reported alongside the budget numbers (script-emitted, fast-pathed — see `finding-verification.md`, no re-grounding needed). `NO-UNIQUE-ANCHOR` has three distinct shapes, never collapse them: (1) the skill owns anchor-grade token(s), but every one is also claimed by another skill; (2) it states a trigger sentence naming no anchor-grade token at all; (3) it names no anchor-grade token anywhere and states no trigger sentence either. Shapes 1 and 2 are structurally un-anchorable — wording cannot create uniqueness; remediation is accept the overlap or merge with the skill that owns the artifact, never "write a better description". Shape 3 is different: the skill hasn't tried — remediation is name the specific artifact or term it uniquely handles, not just a generic verb.

## Remediation order (cheapest first)

When `SKILL-BUDGET-OVERFLOW` fires, the report's "Skill Listing Budget" block MUST list these options verbatim — don't collapse the list; each has different cost and reversibility.

1. **Trim descriptions in source** — for the top 5 bloat contributors, tighten `description` + `when_to_use`. Anthropic's first recommendation: "trim the description and when_to_use text at the source: put the key use case first." Zero ongoing cost.
2. **Disable irrelevant skills per-project** — for each `SKILL-LOW-RELEVANCE` candidate, suggest `/skills` or `skillOverrides: {"<name>": "off"}` (or `"name-only"` to keep it invocable) in the project's settings.json. Per-project overrides don't affect other repos.
3. **Trim `enabledPlugins`** — if an enabled plugin's skills go unused here, propose removing it from `enabledPlugins` in user settings. Plugins are per-machine; check `git log` and recent invocations first (don't disable a plugin enabled this week).
4. **Raise the budget — last resort** — `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var or `skillListingBudgetFraction` in user settings (e.g. `0.02`). Trade-off per `/doctor`'s warning: ~4k extra tokens/turn, faster rate-limit burn. Only suggest once 1–3 are exhausted.

When `SKILL-DUPLICATE-DOMAIN` fires, propose merging or deleting one of the pair instead of disabling — duplicates are a design issue, not a budget issue. Overlapping siblings are a recall tax independent of budget: merging two has been measured to raise combined observed recall 0.68 → 0.84 with neither description getting smarter. Prefer merge over delete when both have real usage history (`skill-usage-metrics.md`) — deleting the less-used one discards capability instead of consolidating it.

## Cross-check at runtime

The script's cost is a static estimate. To compare it with what Claude Code itself measures, run `claude plugin details <name>` ("Show a plugin's component inventory and projected token cost") for a plugin, or `/skill-doctor` inside a session ("Show what each of your skills costs in context and how often it gets used"). `/skill-doctor` needs Claude Code v2.1.252 or later and is unavailable in sessions that skip feature-flag fetching. Treat a large gap between the two as a reason to re-check the script's assumptions, not as a finding.

## Report block (emitted from Phase 24)

```
### Skill Listing Budget                  ← omit if no overflow and no candidates
- Source:   SLASH_COMMAND_TOOL_CHAR_BUDGET=<env or 'unset'>, skillListingBudgetFraction=<value or default>
- Effective: ~Xk chars (~Yk tokens at 4 chars/token)
- Counted:  ~Zk chars across N user+project skills (script lower bound; plugins/marketplace/bundled excluded)
- Verdict:  OK | OVER by Wk chars
- Bloat top 5: <skill> (Nb), …
- Disable candidates (zero hits in project): <names>
- Suggested actions (cheapest first):
  1. Trim description+when_to_use on bloat top 5 (zero ongoing cost)
  2. Disable low-relevance skills via /skills, OR add skillOverrides entries to project settings.json
  3. Remove unused plugins from enabledPlugins in user settings.json — list candidates: <plugin names not invoked recently>
  4. Last resort: raise SLASH_COMMAND_TOOL_CHAR_BUDGET or skillListingBudgetFraction (cost: ~4k tokens/turn, faster rate-limit burn — per /doctor warning)
```
