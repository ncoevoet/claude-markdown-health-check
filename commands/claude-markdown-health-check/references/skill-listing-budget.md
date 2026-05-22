# Skill Listing Budget Audit

Loaded by `/claude-markdown-health-check` Phase 5a. Audits whether the cumulative skill-listing block fits Claude Code's runtime budget and proposes remediations.

## Why this exists

Per the official skills doc, Claude Code loads every skill's `description` + `when_to_use` into a single listing block at session start. The listing is capped at **1% of the context window with an 8,000-character floor**, and `/doctor` surfaces this as `skillListingBudgetFraction`. When the listing exceeds the budget, descriptions are dropped to name-only — the skill stays invocable by name, but Claude can't auto-route to it because the routing keywords are gone.

The per-entry combined `description` + `when_to_use` is also hard-capped at **1,536 characters** regardless of budget. That cap is enforced by `validate-skills.sh` (`DESCRIPTION-TRUNCATED` warning) — do NOT re-check it in this phase.

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

Budget resolution inside the script (most specific wins): `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var → `skillListingBudgetFraction` from `<scope>/settings.json` (read via `jq` if available) → built-in default 0.01. The fraction is multiplied by `CLAUDE_CONTEXT_TOKENS × 4` and floored at 8 000 chars per the docs.

The script's count covers user + project SKILL.md + commands. Plugin, marketplace and bundled skills (`/loop`, `/simplify`, `/debug`, `/claude-api`, etc.) are NOT counted. The number is a **lower bound** — say so in the report so the user understands `/doctor`'s runtime number can exceed it. If the most recent transcript shows the truncation banner (`+N more`), trust the runtime signal over the script-side count.

## Findings

- **`SKILL-BUDGET-OVERFLOW`** (Critical) — emit when `GRAND_TOTAL > GRAND_BUDGET`, OR when an active session has visibly truncated descriptions in the recent transcript. Report numbers and the top 5 cost contributors by combined `description` + `when_to_use` byte count.
- **`SKILL-LOW-RELEVANCE`** (Structural) — for each user-scope skill (skip project + plugins), grep description keywords ≥ 4 chars against the project source tree, capped to 500 hits. Zero hits → flag as a per-project disable candidate. Advisory; tolerate false positives.
- **`SKILL-DUPLICATE-DOMAIN`** (Structural) — Jaccard similarity ≥ 0.6 across description + when_to_use keyword sets. Two skills covering the same domain waste budget twice.

## Remediation order (cheapest first)

When `SKILL-BUDGET-OVERFLOW` fires, the report's "Skill Listing Budget" block MUST list these options verbatim so the user can pick one. Do not collapse the list — each option has different cost and reversibility.

1. **Trim descriptions in source** — for the top 5 bloat contributors, propose tightening `description` + `when_to_use`. Anthropic's own first recommendation: "trim the description and when_to_use text at the source: put the key use case first." Zero ongoing cost.
2. **Disable irrelevant skills per-project** — for each `SKILL-LOW-RELEVANCE` candidate, suggest either `/skills` (interactive) or adding `skillOverrides: {"<name>": "off"}` (or `"name-only"` to keep it invocable) to the project's settings.json. Per-project overrides don't affect other repos.
3. **Trim `enabledPlugins`** — if any enabled plugin provides skills not used in the current project, propose removing it from `enabledPlugins` in the user settings. Plugins are per-machine; check `git log` of the user settings file and recent skill invocations before suggesting (don't propose disabling a plugin the user enabled this week).
4. **Raise the budget — last resort** — `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var (documented) or `skillListingBudgetFraction` in the user settings (e.g., `0.02`). Trade-off the `/doctor` warning calls out: ~4k extra tokens per turn and faster rate-limit burn. Only suggest if 1–3 are exhausted.

When `SKILL-DUPLICATE-DOMAIN` fires, propose **merging or deleting one of the pair** instead of disabling — duplicates indicate a design issue, not a budget issue.

## Report block (emitted from Phase 8)

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
