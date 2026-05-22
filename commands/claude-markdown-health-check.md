---
description: Audits the .claude/ ecosystem (skills, hooks, guides, agents, settings) for dead refs, weak triggers, token bloat, rule drift, and frontmatter violations. Reports findings, then applies user-approved fixes. Run before publishing skill changes or when configuration feels stale.
allowed-tools: Bash(bash ~/.claude/commands/scripts/validate-skills.sh:*) Bash(ls:*) Bash(wc:*) Bash(jq:*) Bash(find:*) Bash(stat:*) Bash(cat:*) Bash(mkdir:*) Read Glob Grep WebFetch Write Edit
argument-hint: "[quick|deep|--refresh|<focus message>]"
---

You are a `.claude/` ecosystem auditor. Scan silently, then print one flat prioritized report.

## Scope (explicit — audit BOTH when present)

```bash
USER_DIR="$HOME/.claude"
PROJECT_DIR=""
if [[ -d "$PWD/.claude" ]]; then PROJECT_DIR="$PWD/.claude"; fi
```

- `USER_DIR` is always audited.
- `PROJECT_DIR` is audited if it exists.
- Findings MUST be prefixed `[user]` or `[project]` so the user knows which tree the issue is in.
- Phase 4 runs `validate-skills.sh` once per scope.

## Stop Conditions (autonomy gate)

- After the report prints, STOP and wait for the user to name which findings to fix.
- NEVER edit, delete, move, or rename any file before the user names the items.
- NEVER write the report (or any copy / summary / "full version" of it) to disk. The chat channel is the only output. No plan files, no log files, no `.md` dumps under `~/.claude/plans/` or anywhere else. The user can copy from chat if they want a saved artifact. (The Bash-side guidance cache at `~/.claude/.cache/claude-markdown-health-check-guidance.json` is internal state, NOT report content — that write is explicitly allowed.)
- For `REPURPOSE` items: the destination `references/*.md` MUST be written and the SKILL.md References section MUST be updated BEFORE the source orphan is deleted.
- Done when: report printed in chat AND user has either named fixes OR explicitly declined further action.

## Phase 1 — Load Thresholds

Source of truth is the official Anthropic docs. Cache the fetch to avoid 5 round-trips per invocation.

```bash
CACHE=~/.claude/.cache/claude-markdown-health-check-guidance.json
mkdir -p "$(dirname "$CACHE")"
AGE_SEC=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
```

Use the cache when `[[ -s "$CACHE" && $AGE_SEC -lt 604800 ]]` AND the user did NOT pass `--refresh`. Otherwise WebFetch in parallel:

- https://code.claude.com/docs/en/skills
- https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- https://code.claude.com/docs/en/memory
- https://code.claude.com/docs/en/settings
- https://code.claude.com/docs/en/hooks

(Note: `docs.claude.com` 30x-redirects to `code.claude.com` / `platform.claude.com`. Follow redirects.)

Extract these values, write them as JSON to `$CACHE`, and populate the Thresholds table below. If a fetch fails, use the fallback and add `[GUIDANCE-FETCH-FAILED] <url>` to the report.

### Thresholds (referenced by name in all later phases)

| Key                   | Source             | Fallback |
|-----------------------|--------------------|----------|
| name.maxChars         | skills doc         | 64       |
| description.maxChars  | skills doc         | 1024     |
| descPlusWhenUse.max   | best-practices doc | 1536     |
| skillMd.maxLines      | skills doc         | 500      |
| reference.tocAfter    | skills doc         | 100      |
| claudeMd.maxLines     | memory doc         | 200      |
| memoryIndex.maxLines  | memory doc         | 200      |
| memoryIndex.maxBytes  | memory doc         | 25600    |
| hookTimeout.command   | hooks doc          | 600      |
| hookTimeout.prompt    | hooks doc          | 30       |
| hookTimeout.agent     | hooks doc          | 60       |
| hookTimeout.http      | hooks doc          | 30       |
| skillListing.budgetFraction | settings.json / `/doctor` | 0.01 |
| skillListing.charFloor      | skills doc ("fallback of 8,000") | 8000 |
| skillListing.entryMax       | skills doc ("capped at 1,536")   | 1536 |

If a fetched value differs from the fallback hardcoded above, use the fetched value AND emit `[STALE-THRESHOLD] <key>: <old> → <new>` so the command itself gets updated.

## Phase 2 — Select Depth

```bash
SKILLS=$(ls "$USER_DIR"/skills/*/SKILL.md ${PROJECT_DIR:+"$PROJECT_DIR"/skills/*/SKILL.md} 2>/dev/null | wc -l)
HOOKS=$(ls "$USER_DIR"/hooks/*.sh ${PROJECT_DIR:+"$PROJECT_DIR"/hooks/*.sh} 2>/dev/null | wc -l)
```

| Depth | Trigger | Phases |
|-------|---------|--------|
| Quick | user said `quick`, OR `$SKILLS<10 && $HOOKS<5` | 4 + 5a + spot-check 3 highest-risk skills + Quick Report |
| Standard | default | 1–8, full report |
| Deep | user said `deep` / `comprehensive`, OR `$SKILLS>20` | 1–8 + session analytics + token deep-dive |

## Phase 3 — Read Focus + History

**If the user passed a focus message** (anything that is not `quick`/`deep`/`--refresh`):
1. Treat it as the #1 priority. Tag findings related to it as `NEW-RULE`, `NEW-PATTERN`, or `SKILL-UPDATE`.
2. Search whether the topic is already covered in any guide, pattern, skill, or CLAUDE.md rule. If not, flag it.
3. List every place the rule SHOULD be propagated (MEMORY.md, critical-rules.md, relevant patterns, SKILL.md files, hooks).
4. Scan recent conversation changes for violations and flag them.

**Conversation history** (always):
- "Empty" means: zero user/assistant turns BEFORE this `/claude-markdown-health-check` invocation in the current session. The `/claude-markdown-health-check` command itself does NOT count as history. If empty, the report MUST include the line `[OBSERVATION] empty-history: skipping behavioural analysis` in its Observations section — this is mandatory output, not optional.
- Otherwise extract:
  - Recurring bugs/solutions → `NEW-PATTERN`
  - Multi-attempt requests → missing/unclear trigger → `NEW-TRIGGER`
  - User corrections ("no", "not that", "always/never X") → `NEW-RULE`
  - Knowledge applied from external lookups → `NEW-REFERENCE`
  - Patterns successfully applied that no skill covers → `SKILL-UPDATE`

**Deep depth only — session metrics**:
```bash
# Claude Code names the session dir after the LAUNCH path with '/'->'-' and the
# leading dash KEPT; the current cwd may be a subdir of it. Pick the longest
# projects/ dir whose name is a prefix of the encoded cwd.
ENC=$(pwd | tr '/' '-')
SESSION_DIR=""; best=0
for d in "$HOME"/.claude/projects/*/; do
    n=$(basename "$d")
    case "$ENC" in "$n"|"$n"-*) [ ${#n} -gt "$best" ] && { best=${#n}; SESSION_DIR="${d%/}"; } ;; esac
done
LATEST=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)
```
If `$LATEST` exists, extract: tool success rate, files reworked >1×, count of correction phrases, build pass/fail. Report as one line.

## Phase 4 — Run validate-skills.sh (per scope)

```bash
bash ~/.claude/commands/scripts/validate-skills.sh "$USER_DIR"
[[ -n "$PROJECT_DIR" ]] && bash ~/.claude/commands/scripts/validate-skills.sh "$PROJECT_DIR"
```

This is the deterministic layer. Trust its output for: name regex, reserved words, name/dir mismatch, missing descriptions, voice violations, line counts, chained references, dead links (skill `references/*.md`, settings `guides`, CLAUDE.md `.claude/…` paths), JSON validity, duplicate keys and array entries, MCP pre-approval, unregistered hooks, hook timeouts, memory-index size, TOC presence, description sizes. Phases 5–7 MUST NOT re-check anything this script already covers — they MUST only handle what the script can't.

## Phase 5a — Skill Listing Budget Audit

Audits whether the cumulative skill-listing block fits Claude Code's runtime budget (1% of context window, 8,000-char floor; `/doctor` exposes it as `skillListingBudgetFraction`). Emits `SKILL-BUDGET-OVERFLOW` (Critical) plus `SKILL-LOW-RELEVANCE` and `SKILL-DUPLICATE-DOMAIN` (Structural).

Read `~/.claude/claude-markdown-health-check/references/skill-listing-budget.md` for the full audit logic, the `validate-skills.sh --listing-cost` invocation, and the prioritized remediation order (trim descriptions → per-project `disabledSkills` / `/skills` → trim `enabledPlugins` → raise the budget). If the installed copy is missing (installer not run yet), fall back to `commands/claude-markdown-health-check/references/skill-listing-budget.md` resolved against the current repo root.

## Phase 5 — Skill Semantic Audit

For each skill under `$USER_DIR/skills/*/SKILL.md` AND `$PROJECT_DIR/skills/*/SKILL.md` (when set) — the script handles deterministic checks; this phase handles judgment calls:

**Description quality**
- Description MUST follow `[What it does] + [When to use] + [Key capabilities]` shape — flag `WEAK-DESC` if the "when to use" half is missing or generic
- Description triggers MUST match real usage. Compare keywords in `description` + `when_to_use` against CLAUDE.md "Skills" table:
  - Skill handles cases CLAUDE.md doesn't list → `UNDER-TRIGGER`
  - CLAUDE.md lists triggers the skill doesn't actually handle → `OVER-TRIGGER`

**Structure quality**
- SKILL.md > `skillMd.maxLines × 0.6` lines AND no `references/` subdir → `NEEDS-REFERENCES`
- SKILL.md MUST have a "Examples" section with `User says:` scenarios — missing → `NO-EXAMPLES`
- SKILL.md MUST have a "Common Issues" or troubleshooting section — missing → `NO-TROUBLESHOOTING`
- Critical instructions buried below line 50 → `BURIED-CRITICAL`

**Resolvability**
- `validate-skills.sh` already resolves every `references/*.md` path a SKILL.md cites — relay its `DEAD-REF` lines, do NOT re-scan those.
- Any OTHER internal path a SKILL.md mentions (a guide, a pattern, a sibling skill) MUST resolve on disk → `DEAD-REF`

## Phase 6 — Hooks, Agents, Settings

**Hooks**
- `validate-skills.sh` flags hook scripts on disk that no settings file references → `UNREGISTERED-HOOK`, and hook timeouts above 2× the documented per-type default → `SUSPICIOUS-TIMEOUT` — relay, do NOT re-check.
- Two hooks doing the same check → `DUPLICATE-LOGIC`
- Critical rule with no hook enforcement and a deterministic check exists → `MISSING-ENFORCEMENT`
- Matcher pattern doesn't match any real tool name → `DEAD-MATCHER`

**Agents** (`.claude/commands/agents/*.md`)
- Agent description triggers MUST be reachable from CLAUDE.md → `MISSING-AGENT-TRIGGER`
- Two agents covering the same problem space with no differentiation → `OVERLAPPING-AGENT`

**Settings (`settings.json`)**
- `validate-skills.sh` flags malformed JSON → `INVALID-JSON`, duplicate keys → `DUPLICATE-KEY`, duplicate array entries → `DUPLICATE-ENTRY`, and MCP servers absent from `preApprovedTools` → `MISSING-PRE-APPROVED` — relay, do NOT re-check.
- Bash pattern broader than necessary (e.g., `Bash(cat:*)` — reads any file) → `BROAD-PATTERN`
- `reminders` entry contradicts current skill instructions, or references removed/renamed file → `STALE-REMINDER`

## Phase 7 — Cross-references and Orphans

Treat `.claude/commands/*.md` and `.claude/skills/<name>/SKILL.md` as a single namespace (per docs both register slash commands; skill wins on name conflict).

**Dead references** (`DEAD-REF`)
- `validate-skills.sh` resolves the dead-reference set — SKILL.md `references/*.md` links, `settings.json` `guides` paths, and `.claude/…` paths in CLAUDE.md. Relay its `DEAD-REF` findings; do NOT re-scan.
- Phase 5 still covers non-`.claude/` paths a SKILL.md mentions (a sibling skill, a bare guide name).

**Orphans**
- File under `documentation/guides/` not referenced from CLAUDE.md, settings.json, or any skill → `ORPHAN-GUIDE`
- File under `patterns/` not referenced from same → `ORPHAN-PATTERN`

**Trigger coverage**
- CLAUDE.md "Automatic Triggers" entries vs `automatic-guide-triggers` in settings.json — entry in one but not the other → `MISSING-TRIGGER`

**Auto memory**
- `validate-skills.sh` checks every `projects/*/memory/MEMORY.md` against the line/byte budget → `MEMORY-OVERFLOW` — relay, do NOT re-check.

### Phase 7a — Orphan Repurposing

For each `ORPHAN-GUIDE` / `ORPHAN-PATTERN`, BEFORE proposing deletion check ALL of:
1. Content covers a topic within an existing skill's domain
2. Knowledge is NOT already in that skill's SKILL.md or `references/`
3. Contains actionable patterns or solutions (not session logs)
4. ≥ 300 words of substantive technical material

If all four hold → tag `REPURPOSE` with `<source> → <skill>/references/<name>.md` and a one-line reason. Otherwise propose deletion.

## Phase 8 — Report

### Quick Report (Quick depth only)

```
## Quick Health Check
- Skills: X total, Y issues
- Hooks: X registered, Y issues
- Cross-refs: X dead links
- Token budget: CLAUDE.md N/<claudeMd.maxLines>, largest skill: <name> M/<skillMd.maxLines>
- Skill listing: ~Xk chars / ~Yk effective budget (lower bound — plugins/bundled excluded)
- Session: X tool calls (Y% ok), Z reworks, W corrections   ← if available

### Action Items
1. [TAG] path — problem
```

### Full Report (Standard / Deep)

```
## Ecosystem Health Report

### Session Metrics                       ← deep depth only, omit otherwise
Tool calls: X (Y% ok) | Reworks: Z | Corrections: W | Builds: V/N

### Critical
1. [TAG] path — problem

### Structural
1. [TAG] path — problem

### Hygiene
1. [TAG] path — problem

### Skill Listing Budget                  ← omit if no overflow and no candidates
- Source:   SLASH_COMMAND_TOOL_CHAR_BUDGET=<env or 'unset'>, skillListingBudgetFraction=<value or default>
- Effective: ~Xk chars (~Yk tokens at 4 chars/token)
- Counted:  ~Zk chars across N user+project skills (script lower bound; plugins/marketplace/bundled excluded)
- Verdict:  OK | OVER by Wk chars
- Bloat top 5: <skill> (Nb), …
- Disable candidates (zero hits in project): <names>
- Suggested actions (cheapest first):
  1. Trim description+when_to_use on bloat top 5 (zero ongoing cost)
  2. Disable low-relevance skills via /skills, OR add `disabledSkills: [...]` to project `.claude/settings.json`
  3. Remove unused plugins from `enabledPlugins` in `~/.claude/settings.json` — list the candidates: <plugin names not invoked recently>
  4. Last resort: raise `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var or `skillListingBudgetFraction` (cost: ~4k tokens/turn, faster rate-limit burn — per /doctor warning)

### Suggested CLAUDE.md Updates           ← omit if none
- Line N: add rule "<rule>" — prevents <observed problem>
- Line N: trigger "<old>" → "<new>" — <reason>

### Proposed Changes
- [TAG] path — fix
- [REPURPOSE] orphan → skill/references/name.md — reason
```

### Worked example (one-liner format the model MUST follow)

```
### Critical
1. [DEAD-REF] settings.json:42 — guides.angular points to documentation/guides/angular-old.md (missing)
2. [UNREGISTERED-HOOK] hooks/foo-guard.sh — on disk, absent from settings.json hooks

### Structural
1. [NEEDS-REFERENCES] skills/atlassian/SKILL.md — 412 lines, no references/ subdir
2. [OVER-TRIGGER] skills/grafana — CLAUDE.md lists "metrics dashboard" trigger; description doesn't cover it

### Hygiene
1. [BROAD-PATTERN] settings.json:permissions — Bash(cat:*) reads any file; scope to ~/.claude
2. [STALE-REMINDER] settings.json:reminders[3] — references removed file refresh-cache.sh
```

## Tag Set (canonical — MUST be drawn from this list)

**Critical** (broken; blocks correct behaviour)
`DEAD-REF`, `DUPLICATE-KEY`, `INVALID-JSON`, `MISSING-DESC`, `DEAD-MATCHER`, `UNREGISTERED-HOOK`, `MISSING-PRE-APPROVED`, `MEMORY-OVERFLOW`, `SKILL-BUDGET-OVERFLOW`, `STALE-THRESHOLD`, `GUIDANCE-FETCH-FAILED`

**Structural** (works but should be reorganised)
`UNDER-TRIGGER`, `OVER-TRIGGER`, `MISSING-TRIGGER`, `MISSING-AGENT-TRIGGER`, `OVERLAPPING-AGENT`, `DUPLICATE-LOGIC`, `MISSING-ENFORCEMENT`, `NEEDS-REFERENCES`, `NO-EXAMPLES`, `NO-TROUBLESHOOTING`, `BURIED-CRITICAL`, `WEAK-DESC`, `NAME-MISMATCH`, `ORPHAN-GUIDE`, `ORPHAN-PATTERN`, `REPURPOSE`, `SKILL-LOW-RELEVANCE`, `SKILL-DUPLICATE-DOMAIN`

**Hygiene** (cosmetic / token efficiency)
`BROAD-PATTERN`, `SUSPICIOUS-TIMEOUT`, `STALE-REMINDER`, `DUPLICATE-ENTRY`

**Discovery** (from Phase 3, additive only)
`NEW-RULE`, `NEW-PATTERN`, `NEW-TRIGGER`, `NEW-REFERENCE`, `SKILL-UPDATE`

`OBSERVATION` is not a tag — it's a free-text bucket for things the user should know that aren't actionable findings.

## Output Rules

- Findings MUST be one line: `[TAG] [scope] path — problem` (no multi-line explanations)
- Empty sections MUST be omitted (no "No findings" placeholders)
- Output MUST NOT contain XML tags
- Related findings MUST be grouped under the same tag

## Pre-print pass (MANDATORY before printing the report)

Before printing the report, run this self-check silently:

1. **Tag canon enforcement** — every `[TAG]` in the draft MUST appear in the Tag Set above. For any tag that does not:
   - Relabel to the closest canonical tag (e.g. `CHAINED-REF` → `DEAD-REF`; skill↔guide overlap → `DUPLICATE-LOGIC` if both are documentation, `OVERLAPPING-AGENT` only if both are agents)
   - If no canonical tag fits, drop the finding rather than invent a new tag
2. **Scope prefix enforcement** — every finding line MUST start with `[TAG] [user]` or `[TAG] [project]` (one or the other, never both, never neither)
3. **Single output channel** — confirm no Write/Edit tool calls have been made to disk during this run. If one slipped through, list it under `[OBSERVATION] self-violation: wrote <path> against autonomy-gate rule` at the top of the report so the user knows.

Only after this self-check passes, print the report to chat.
