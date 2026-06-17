---
description: Audits the .claude/ ecosystem (skills, hooks, guides, agents, settings, plugins, memory) for dead refs, weak triggers, token bloat, rule drift, frontmatter violations, dormant skills, hook reliability, permission drift, memory hygiene, and context bloat. Reports findings, then applies user-approved fixes. Run before publishing skill changes or when configuration feels stale.
allowed-tools: Bash(bash ~/.claude/commands/scripts/validate-skills.sh:*) Bash(bash:*commands/scripts/validate-skills.sh:*) Bash(bash ~/.claude/commands/scripts/scan-graph.sh:*) Bash(bash:*commands/scripts/scan-graph.sh:*) Bash(bash ~/.claude/commands/scripts/scan-history.sh:*) Bash(bash:*commands/scripts/scan-history.sh:*) Bash(ls:*) Bash(wc:*) Bash(jq:*) Bash(find:*) Bash(stat:*) Bash(cat:*) Bash(mkdir:*) Bash(date:*) Read Glob Grep WebFetch Write Edit
argument-hint: "[quick|deep|--refresh|--compress-bodies|--window-days=N|<focus message>]"
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
- Phase 5 runs `validate-skills.sh` once per scope. Phase 2/7/11/15/16/19/20/22/23 read the cached scan outputs.

## Stop Conditions (autonomy gate)

- After the report prints, run Phase 25 — present the post-report action menu. Do not apply any fix until the user picks a scope through it.
- NEVER edit, delete, move, or rename any file before the user picks a menu scope.
- NEVER write the report (or any copy / summary / "full version" of it) to disk. The chat channel is the only output. (Cache files at `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/{claude-markdown-health-check-guidance,graph-scan,history-scan}.json` are internal state, NOT report content — those writes are explicitly allowed.)
- For `REPURPOSE` items: the destination `references/*.md` MUST be written and the SKILL.md References section MUST be updated BEFORE the source orphan is deleted.
- Done when: report printed in chat AND user has either named fixes OR explicitly declined further action.

## Phase 1 — Load Config + Thresholds

### Config (optional)

Load `.claude/markdown-health-check.json` if present — user defaults merged with project overrides, CLI args winning. See `config-keys.md` for every key, default, and the precedence rule (**CLI > project > user > default**).

```bash
CFG="$(jq -s '.[0] * .[1]' \
        <(jq '.' "$HOME/.claude/markdown-health-check.json" 2>/dev/null || echo '{}') \
        <(jq '.' "$PWD/.claude/markdown-health-check.json"  2>/dev/null || echo '{}') \
        2>/dev/null || echo '{}')"
WINDOW="${WINDOW:-$(jq -rn --argjson c "$CFG" '$c.windowDays // 30')}"   # --window-days wins
VERIFY_FINDINGS="$(jq -rn --argjson c "$CFG" '$c.verifyFindings // true')"
SEVERITY_FLOOR="$(jq -rn  --argjson c "$CFG" '$c.severityFloor // "polish"')"
MAX_PER_DOMAIN="$(jq -rn  --argjson c "$CFG" '$c.maxFindingsPerDomain // 0')"
SKIP_PHASES="$(jq -rn     --argjson c "$CFG" '($c.skipPhases // []) | join(" ")')"
TTL_DAYS="$(jq -rn        --argjson c "$CFG" '$c.guidanceCacheTtlDays // 7')"
```

Apply them: `depth`/`quick`/`deep` CLI args override `CFG.depth` in Phase 3; `WINDOW` feeds the telemetry phases; `VERIFY_FINDINGS` gates the Pre-print grounding step (off ⇒ judgment findings emitted unverified); `SKIP_PHASES` removes phases (**Phase 5 is never skippable** — it is the deterministic spine); `SEVERITY_FLOOR`/`MAX_PER_DOMAIN` shape the report (Phase 24); `compressBodies` mirrors `--compress-bodies` (Phase 13). If the config file is present but invalid JSON, emit `[OBSERVATION] config: markdown-health-check.json is not valid JSON — using defaults` and proceed with defaults.

### Thresholds (fetch + cache)

Source of truth is the official Anthropic docs. Cache the fetch to avoid 5 round-trips per invocation.

```bash
CACHE="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}/claude-markdown-health-check-guidance.json"
mkdir -p "$(dirname "$CACHE")"
AGE_SEC=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
TTL_SEC=$(( ${TTL_DAYS:-7} * 86400 ))
```

Use the cache when `[[ -s "$CACHE" && $AGE_SEC -lt $TTL_SEC ]]` AND the user did NOT pass `--refresh`. Otherwise WebFetch in parallel:

- https://code.claude.com/docs/en/skills
- https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- https://code.claude.com/docs/en/memory
- https://code.claude.com/docs/en/settings
- https://code.claude.com/docs/en/hooks

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
| hookTimeout.http      | hooks doc          | 600      |
| skillListing.budgetFraction | settings.json / `/doctor` | 0.01 |
| skillListing.charFloor      | skills doc ("fallback of 8,000") | 8000 |
| skillListing.entryMax       | skills doc ("capped at 1,536")   | 1536 |

If a fetched value differs from the fallback hardcoded above, use the fetched value AND emit `[STALE-THRESHOLD] <key>: <old> → <new>` so the command itself gets updated.

Note: a `command` hook under a `UserPromptSubmit` event defaults to 30s (not 600s) — `validate-skills.sh` accounts for this in `SUSPICIOUS-TIMEOUT`.

## Phase 2 — Plugin Install Integrity

Static check of `~/.claude/plugins/installed_plugins.json` vs the on-disk cache. Standard + Deep; skipped at Quick.

```bash
GRAPH="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}/graph-scan.json"
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/scripts/scan-graph.sh" "$USER_DIR" >/dev/null
jq -r '.findings[] | select(.phase == 2)' "$GRAPH"
```

See `plugin-integrity.md` for tag definitions (`PLUGIN-BROKEN-REF`, `PLUGIN-MISSING-MANIFEST`, `PLUGIN-VERSION-DRIFT`) and remediation order. The same phase-2 pass also flags deprecated MCP transport (`MCP-DEPRECATED-TRANSPORT`): an `mcpServers` entry of `"type":"sse"` in `.mcp.json`, `~/.claude.json`, or a settings file.

When the scanned tree is a **plugin root** (a `.claude-plugin/plugin.json` is present), the phase-2 pass also validates the plugin's own structure (any scope, so the tool dogfoods on plugin repos): a component dir (`skills`/`agents`/`commands`/`hooks`/`output-styles`/`monitors`) nested inside `.claude-plugin/` → `PLUGIN-MISPLACED-DIR`; a missing or non-semver `version` → `PLUGIN-BAD-VERSION`; a declared component path that isn't relative-with-`./` → `PLUGIN-ABS-PATH`; a `marketplace.json` plugin `source` that resolves to no directory → `MARKETPLACE-DEAD-SOURCE`.

## Phase 3 — Select Depth

```bash
SKILLS=$(ls "$USER_DIR"/skills/*/SKILL.md ${PROJECT_DIR:+"$PROJECT_DIR"/skills/*/SKILL.md} 2>/dev/null | wc -l)
HOOKS=$(ls "$USER_DIR"/hooks/*.sh ${PROJECT_DIR:+"$PROJECT_DIR"/hooks/*.sh} 2>/dev/null | wc -l)
```

| Depth | Trigger | Phases |
|-------|---------|--------|
| Quick | user said `quick`, OR `$SKILLS<10 && $HOOKS<5` | 1, 5, 6, 10, 21, 24, 25 + spot-check 3 highest-risk skills |
| Standard | default | 1–18, 20, 24, 25 |
| Deep | user said `deep` / `comprehensive`, OR `$SKILLS>20` | 1–25 (full) |

`--window-days=N` overrides the 30-day default used by Phases 7, 9, 15, 16, 19, 22, 23. When no `quick`/`deep` arg is given, the `depth` config key (`config-keys.md`) sets the floor; `SKIP_PHASES` (config) then removes any listed phases from the selected set — except Phase 5, which always runs.

## Phase 4 — Read Focus + History

**If the user passed a focus message** (anything that is not `quick`/`deep`/`--refresh`/`--compress-bodies`/`--window-days=*`):
1. Treat it as the #1 priority. Tag findings related to it as `NEW-RULE`, `NEW-PATTERN`, or `SKILL-UPDATE`.
2. Search whether the topic is already covered in any guide, pattern, skill, or CLAUDE.md rule. If not, flag it.
3. List every place the rule SHOULD be propagated (MEMORY.md, critical-rules.md, relevant patterns, SKILL.md files, hooks).
4. Scan recent conversation changes for violations and flag them.

**Conversation history** (always):
- "Empty" means: zero user/assistant turns BEFORE this `/claude-markdown-health-check` invocation in the current session. The command itself does NOT count as history. If empty, the report MUST include `[OBSERVATION] empty-history: skipping behavioural analysis` — mandatory output.
- Otherwise extract:
  - Recurring bugs/solutions → `NEW-PATTERN`
  - Multi-attempt requests → missing/unclear trigger → `NEW-TRIGGER`
  - User corrections ("no", "not that", "always/never X") → `NEW-RULE`
  - Knowledge applied from external lookups → `NEW-REFERENCE`
  - Patterns successfully applied that no skill covers → `SKILL-UPDATE`

**Deep depth current-session metrics**:
```bash
ENC=$(pwd | tr '/' '-')
SESSION_DIR=""; best=0
for d in "$HOME"/.claude/projects/*/; do
    n=$(basename "$d")
    case "$ENC" in "$n"|"$n"-*) [ ${#n} -gt "$best" ] && { best=${#n}; SESSION_DIR="${d%/}"; } ;; esac
done
LATEST=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)
```
If `$LATEST` exists, extract: tool success rate, files reworked >1×, count of correction phrases, build pass/fail. Report as one line in the Session Metrics block. Cross-session aggregates are owned by Phase 19, not this phase.

## Phase 5 — Run validate-skills.sh (per scope)

```bash
VALIDATE="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/scripts/validate-skills.sh"
bash "$VALIDATE" "$USER_DIR"
[[ -n "$PROJECT_DIR" ]] && bash "$VALIDATE" "$PROJECT_DIR"
```

This is the deterministic layer. Trust its output for: name regex, reserved words, name/dir mismatch, missing descriptions, voice violations, line counts, chained references, dead links (skill `references/*.md`, settings `guides`, CLAUDE.md `.claude/…` paths), JSON validity, duplicate keys and array entries, MCP pre-approval, unregistered hooks, hook timeouts, memory-index size, rule scoping, TOC presence, description sizes, frontmatter schema (description min length, `model` whitelist, `allowed-tools` syntax), unknown frontmatter fields, name collisions between `commands/` and `skills/`, embedded credentials in skill/reference markdown (`EMBEDDED-SECRET`), and destructive shell commands without nearby warning markers (`UNFLAGGED-DESTRUCTIVE`). Later phases MUST NOT re-check anything this script already covers — they MUST only handle what the script can't.

## Phase 6 — Skill Listing Budget

Audits whether the cumulative skill-listing block fits Claude Code's runtime budget. Emits `SKILL-BUDGET-OVERFLOW` (Critical) plus `SKILL-LOW-RELEVANCE` and `SKILL-DUPLICATE-DOMAIN` (Structural). See `skill-listing-budget.md` for the full logic, the `validate-skills.sh --listing-cost` invocation, and the remediation order. Resolution: first that exists of `${CLAUDE_PLUGIN_ROOT}/commands/claude-markdown-health-check/references/skill-listing-budget.md`, `~/.claude/claude-markdown-health-check/references/skill-listing-budget.md`, or the repo copy.

## Phase 7 — Skill Usage Metrics

Cross-session invocation, dormancy, and orphan detection over the 30-day window. Standard + Deep.

```bash
HIST="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}/history-scan.json"
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/scripts/scan-history.sh" ${WINDOW:+--window-days "$WINDOW"} >/dev/null
```

See `skill-usage-metrics.md` for the heuristic formulas and tag definitions (`SKILL-NEVER-FIRED`, `SKILL-DORMANT`, `SKILL-MISFIRING`, `SKILL-ORPHAN`). Findings reference skill names only; wording must say "in this install" since `.skillUsage` is per-machine.

## Phase 8 — Skill Semantic Audit

For each skill under `$USER_DIR/skills/*/SKILL.md` AND `$PROJECT_DIR/skills/*/SKILL.md` (when set) — the script handles deterministic checks; this phase handles judgment calls:

**Description quality**
- Description MUST follow `[What it does] + [When to use] + [Key capabilities]` shape — flag `WEAK-DESC` if the "when to use" half is missing or generic.
- Description triggers MUST match real usage. Compare keywords in `description` + `when_to_use` against CLAUDE.md "Skills" table:
  - Skill handles cases CLAUDE.md doesn't list → `UNDER-TRIGGER`
  - CLAUDE.md lists triggers the skill doesn't actually handle → `OVER-TRIGGER`

**Structure quality**
- SKILL.md > `skillMd.maxLines × 0.6` lines AND no `references/` subdir → `NEEDS-REFERENCES`
- SKILL.md MUST have an "Examples" section with `User says:` scenarios — missing → `NO-EXAMPLES`
- SKILL.md MUST have a "Common Issues" or troubleshooting section — missing → `NO-TROUBLESHOOTING`
- Critical instructions buried below line 50 → `BURIED-CRITICAL`

**Resolvability**
- `validate-skills.sh` already resolves every `references/*.md` path a SKILL.md cites — relay its `DEAD-REF` lines, do NOT re-scan.
- Any OTHER internal path a SKILL.md mentions (a guide, a pattern, a sibling skill) MUST resolve on disk → `DEAD-REF`.

## Phase 9 — Skill–Tool Contract

For each skill with ≥3 invocations in `history-scan.json`, compare `allowed-tools` against the tools actually called. See `skill-tool-contract.md`. Tags: `SKILL-TOOL-UNUSED` (Hygiene), `SKILL-TOOL-UNDECLARED` (Structural).

## Phase 10 — Frontmatter Strict Schema

Already implemented as part of Phase 5's deterministic checks: `validate-skills.sh` validates `description` min length, `model` whitelist, `allowed-tools` syntax, and emits `UNKNOWN-FRONTMATTER-FIELD` for unknown keys. See `frontmatter-schema.md` for the tag rubric. No separate phase action needed — relay Phase 5 output.

## Phase 11 — Reference Graph Health

Cycles, depth violations, and orphan ref files across the `references/*.md` graph. See `reference-graph.md`. Tags: `REF-CIRCULAR` (Critical), `REF-TOO-DEEP` (Structural), `REF-ORPHAN` (Hygiene). Reads `graph-scan.json` findings with `.phase == 11`.

## Phase 12 — CLAUDE.md Content Quality

This phase judges whether each CLAUDE.md / `CLAUDE.local.md` in scope is actually *useful* to a fresh session. Read `claude-md-quality.md` for the rubric. For each CLAUDE.md found, verify its commands and paths against the real tree, then emit:
- A command, path, or version CLAUDE.md states that the codebase contradicts → `CLAUDEMD-STALE`
- Generic boilerplate not specific to this repo → `CLAUDEMD-GENERIC`
- No build/test/run commands, or no architecture map → `CLAUDEMD-THIN`

Skip at Quick depth. A short but accurate CLAUDE.md is not a finding.

Deterministic CLAUDE.md checks run inside `validate-skills.sh` (Phase 5) and relay here: an `@path` import that does not resolve → `CLAUDEMD-DEAD-IMPORT`; an `@import` chain deeper than the 4-hop limit → `IMPORT-TOO-DEEP`; a `CLAUDE.local.md` inside a git repo with no covering `.gitignore` entry → `LOCAL-MD-TRACKED`. See `claude-md-quality.md`.

## Phase 13 — Body Compression (detection + opt-in rewrite)

Detects prose drift in skill bodies, rule bodies, and reference files. Detection always runs at Standard + Deep depth and emits `BODY-FILLER-HIGH` (Hygiene). Rewrite sub-phase is opt-in only — triggered by `--compress-bodies` or the `compressBodies` config key.

See `body-compression.md` for the filler-density formula, candidate selection rules, the constrained cavecrew-builder prompt template, post-rewrite validation gates, and the idempotency marker convention.

Detection summary:
- For each `*.md` under `skills/*/SKILL.md`, `rules/*.md`, `documentation/guides/*.md`, `patterns/*.md`, and `skills/*/references/*.md`:
  - Skip when body < 150 lines, when ≥ 70% of body is fenced code, when the file carries `<!-- caveman:lite v1 -->` or `<!-- DO NOT COMPRESS -->`.
  - Compute filler density excluding YAML frontmatter and fenced code.
  - Emit `[BODY-FILLER-HIGH] [scope] path — N% filler over M body words; run --compress-bodies to fix` when density > 6%.

Rewrite mode (when `--compress-bodies`):
- Verify caveman plugin is installed; offer install via `AskUserQuestion` once.
- Refuse when working tree is dirty for any candidate path.
- For each candidate (max 10, sorted by `filler_hits × body_lines` desc), spawn `caveman:cavecrew-builder` with the constrained prompt.
- Reject when section/bullet/fence/frontmatter count changes; restore from git and emit `BODY-COMPRESSION-REJECTED`.
- Reject when body delta < 8% or > 25%; restore and report.
- On success, append `<!-- caveman:lite v1 -->` and emit `BODY-COMPRESSED`.
- After all candidates, present a batch commit menu via `AskUserQuestion`; land on `chore/caveman-lite-bodies-<date>` branch. Never push.

## Phase 14 — Hooks, Agents, Settings

**Hooks**
- `validate-skills.sh` flags hook scripts on disk that no settings file references → `UNREGISTERED-HOOK`, and hook timeouts above 2× the documented per-type default → `SUSPICIOUS-TIMEOUT` — relay.
- `validate-skills.sh` statically scans hook scripts and http hook config (see `references/hook-safety.md`) → hook script with no `#!` shebang → `HOOK-NO-SHEBANG`; a script that emits a block/deny decision but exits 1 instead of 2 (exit 1 is non-blocking) → `HOOK-EXIT-NONBLOCKING`; `eval` of a dynamic value → `HOOK-UNSAFE-SHELL`; an http hook with an auth header but no `allowedEnvVars`/`httpHookAllowedEnvVars` → `HOOK-ENV-LEAK` — relay.
- Two hooks doing the same check → `DUPLICATE-LOGIC`
- Critical rule with no hook enforcement and a deterministic check exists → `MISSING-ENFORCEMENT`
- Matcher pattern doesn't match any real tool name → `DEAD-MATCHER`. ONLY for tool-events (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied`) whose matcher IS a tool name. For event-typed matchers the matcher is an event-specific string, NOT a tool — never flag those: `SessionStart` (`startup|resume|clear|compact`), `PreCompact`/`PostCompact` (`manual|auto`), `SessionEnd`, `Notification`, `SubagentStart`/`SubagentStop`, `ConfigChange`, etc. See `references/hook-reliability.md` for the event→matcher table

**Agents** (`.claude/agents/*.md`)
- `validate-skills.sh` validates every subagent file against the subagent schema (distinct from the skill schema — see `references/agent-frontmatter.md`) and relays: bad `model`/`color`/`permissionMode` value, malformed `tools`/`disallowedTools`, missing `description`, or bad `name` charset → `AGENT-BAD-SCHEMA`; `permissionMode: bypassPermissions` → `AGENT-BYPASS-PERMS`; two agent files sharing a `name` → `AGENT-DUP-NAME`; a plugin-tree agent declaring `hooks`/`mcpServers`/`permissionMode` (silently ignored) → `AGENT-PLUGIN-FORBIDDEN-FIELD` — relay.
- Agent description triggers MUST be reachable from CLAUDE.md → `MISSING-AGENT-TRIGGER`
- Two agents covering the same problem space with no differentiation → `OVERLAPPING-AGENT`

**Settings (`settings.json`)**
- `validate-skills.sh` flags malformed JSON → `INVALID-JSON`, duplicate keys → `DUPLICATE-KEY`, duplicate array entries → `DUPLICATE-ENTRY`, MCP servers absent from `preApprovedTools`/`permissions.allow` → `MISSING-PRE-APPROVED`, `defaultMode: bypassPermissions` → `SETTINGS-BYPASS-MODE`, `enableAllProjectMcpServers: true` → `SETTINGS-MCP-AUTOAPPROVE` — relay.
- Bash pattern broader than necessary (e.g., `Bash(cat:*)`) → `BROAD-PATTERN`
- `reminders` entry contradicts current skill instructions, or references removed/renamed file → `STALE-REMINDER`
- Current settings keys are valid — do not flag `permissions`, `skillOverrides`, `maxSkillDescriptionChars`, `claudeMdExcludes`, `autoMemoryDirectory`, `autoMemoryEnabled`, `enabledPlugins`, `outputStyle`, `defaultMode`, `enableAllProjectMcpServers`, `disableBypassPermissionsMode`, `enabledMcpjsonServers`, `disabledMcpjsonServers`.

## Phase 15 — Permission Allowlist Hygiene

Cross-references `settings.json#permissions.allow` against the cross-session denial and tool-call signal in `history-scan.json`. See `permission-hygiene.md`. Tags: `PERM-DEAD-ENTRY` (Hygiene), `PERM-OVERBROAD` (Hygiene). `PERM-MISSING-ENTRY` is currently parked (no per-tool denial breakdown available).

## Phase 16 — Hook Latency + Reliability

Per-hook failure-rate from `history-scan.json` → `.hookEvents`. See `hook-reliability.md`. Tags: `HOOK-FAILING` (Structural; **Critical** when failure_rate == 1.0 and total ≥ 5), `HOOK-NEVER-FIRED` (Hygiene), `HOOK-EVENT-MISMATCH` (Structural).

## Phase 17 — Cross-references and Orphans

Treat `.claude/commands/*.md` and `.claude/skills/<name>/SKILL.md` as a single namespace (per docs both register slash commands; skill wins on name conflict).

**Dead references** (`DEAD-REF`)
- `validate-skills.sh` resolves the dead-reference set — SKILL.md `references/*.md` links, `settings.json` `guides` paths, and `.claude/…` paths in CLAUDE.md. Relay; do NOT re-scan.
- Phase 8 still covers non-`.claude/` paths a SKILL.md mentions (a sibling skill, a bare guide name).

**Orphans**
- File under `documentation/guides/` not referenced from CLAUDE.md, settings.json, or any skill → `ORPHAN-GUIDE`
- File under `patterns/` not referenced from same → `ORPHAN-PATTERN`

**Trigger coverage**
- CLAUDE.md "Automatic Triggers" entries vs `automatic-guide-triggers` in settings.json — entry in one but not the other → `MISSING-TRIGGER`

**Auto memory**
- `validate-skills.sh` checks every `projects/*/memory/MEMORY.md` against the line/byte budget → `MEMORY-OVERFLOW` — relay.

**Rules** (`.claude/rules/`)
- `validate-skills.sh` flags rules with no glob → `BAD-RULE-FRONTMATTER`, large unscoped rules → `RULE-OVERSIZED` — relay.

## Phase 18 — Orphan Repurposing

For each `ORPHAN-GUIDE` / `ORPHAN-PATTERN`, BEFORE proposing deletion check ALL of:
1. Content covers a topic within an existing skill's domain
2. Knowledge is NOT already in that skill's SKILL.md or `references/`
3. Contains actionable patterns or solutions (not session logs)
4. ≥ 300 words of substantive technical material

If all four hold → tag `REPURPOSE` with `<source> → <skill>/references/<name>.md` and a one-line reason. Otherwise propose deletion.

## Phase 19 — Cross-Session Pattern Mining (Deep only)

Recurring denials, correction clusters, and skill-gap detection. See `cross-session-patterns.md`. Tags: `RECURRING-DENIAL` (Structural), `RECURRING-CORRECTION` (Hygiene), `MISSING-SKILL-GAP` (Critical). `HOOK-FAILING` is owned by Phase 16; this phase does not re-flag.

## Phase 20 — Auto-memory Hygiene

Link-index audit for every `~/.claude/projects/*/memory/MEMORY.md`. See `memory-hygiene.md`. Tags: `MEMORY-DEAD-LINK` (Critical), `MEMORY-ORPHAN-FILE` (Hygiene), `MEMORY-DUP-ENTRY` (Hygiene), `MEMORY-STALE-DATE` (Hygiene). Freeform MEMORY.md files (no link-index lines) are skipped.

## Phase 21 — Name Collisions

Already implemented in Phase 5: `validate-skills.sh` emits `NAME-COLLISION` (Critical) when the same basename exists in both `commands/` and `skills/`. No separate action — relay Phase 5 output.

## Phase 22 — Agents Never-Spawned

For each agent file under `~/.claude/agents/`, check `history-scan.json` → `.agentSpawns`. Emit `AGENT-NEVER-SPAWNED` (Structural) when the subagent never appears in the window. See `cross-session-patterns.md` for the matching algorithm (name + Jaccard fallback).

## Phase 23 — Token Trend (Deep only)

Per-session `message.usage` aggregates from `history-scan.json` → `.tokenUsage`. See `token-trend.md`. Tags: `LOW-CACHE-HIT` (Hygiene), `CONTEXT-BLOAT` (Structural).

## Phase 26 — Output Styles

Static check of `.claude/output-styles/*.md` against the selected `outputStyle` setting (any tree; runs in the scan band — its findings feed the Phase 24 report like every other scanner). Read from the same `graph-scan.json`:

```bash
jq -r '.findings[] | select(.phase == 26)' "$GRAPH"
```

See `output-styles.md` for the tag definition: `OUTPUTSTYLE-MISSING` (Critical — `outputStyle` names a non-existent, non-built-in style). Built-in styles (`Default`, `Proactive`, `Explanatory`, `Learning`) have no file and are never flagged (matched case-insensitively). There is no "orphan style" tag — unselected style files are a legitimate palette, not a defect.

## Phase 24 — Report

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
1. [must-fix] <plain-language problem>                          · TAG
```

### Full Report (Standard / Deep)

Render per `references/report-format.md`: a scorecard, then findings grouped by
DOMAIN (not by severity tier), each a plain-language sentence with a
`[must-fix]`/`[should]`/`[polish]` chip and the tag trailing as a machine code.
Resolve the spec file the same way as `post-report-menu.md`. One scorecard +
grouped block per scope present.

```
## .claude health (<scope>) — grade <A|B|C|D>
issues: <Domain N · Domain N · …>          ← only domains with findings

### Session Metrics                       ← deep depth current-session, omit otherwise
Tool calls: X (Y% ok) | Reworks: Z | Corrections: W | Builds: V/N

### Plugin Integrity                      ← phase 2, omit when clean
### Skill Usage (last 30d)                ← phase 7, omit when no signal
### Reference Graph                       ← phase 11, omit when clean
### Permission Hygiene                    ← phase 15, omit when clean
### Hook Health                           ← phase 16, omit when clean
### Auto-memory                           ← phase 20, omit when clean
### Cross-session patterns (last 30d)     ← phase 19, deep only
### Context Trend (last 30d)              ← phase 23, deep only

## <Domain>                               ← fixed order; omit empty (see report-format.md)
 N. [must-fix] <plain-language problem>
               <path/locator>                                   · TAG

### Suggestions                           ← Discovery [idea] items, omit if none
 N. [idea] <plain-language suggestion>                          · TAG

### Skill Listing Budget                  ← omit if no overflow and no candidates
- Source / Effective / Counted / Verdict / Bloat top 5 / Disable candidates / Suggested actions

### Suggested CLAUDE.md Updates           ← omit if none

### Proposed Changes                      ← keyed to the finding numbers for the Phase 25 menu
- finding N — <fix> · TAG
- [REPURPOSE] orphan → skill/references/name.md — reason
```

### Worked example

```
## .claude health (user) — grade B
issues: Skills 3 · Hooks 1 · Settings & Permissions 1

## Skills
 1. [must-fix] atlassian links to a missing file (references/api.md)
               skills/atlassian/SKILL.md                          · DEAD-REF
 2. [should]   atlassian body is 412 lines with no references/ split
               skills/atlassian/SKILL.md                   · NEEDS-REFERENCES
 3. [should]   atlassian is unused in the last 30 days but loads 4.2k chars per session
               skills/atlassian                               · SKILL-DORMANT

## Hooks
 4. [must-fix] the Edit hook fails on almost every run (284/304, 93%)
               PreToolUse:Edit                                  · HOOK-FAILING

## Settings & Permissions
 5. [polish]   Bash(cat:*) lets any file be read — scope it to ~/.claude
               settings.json                                   · BROAD-PATTERN
```

## Tag Set (canonical — MUST be drawn from this list)

**Critical** (broken; blocks correct behaviour)
`DEAD-REF`, `DUPLICATE-KEY`, `INVALID-JSON`, `MISSING-DESC`, `DEAD-MATCHER`, `UNREGISTERED-HOOK`, `MISSING-PRE-APPROVED`, `MEMORY-OVERFLOW`, `SKILL-BUDGET-OVERFLOW`, `STALE-THRESHOLD`, `GUIDANCE-FETCH-FAILED`, `BAD-FRONTMATTER-SCHEMA`, `NAME-COLLISION`, `SKILL-ORPHAN`, `MISSING-SKILL-GAP`, `PLUGIN-BROKEN-REF`, `PLUGIN-MISSING-MANIFEST`, `MEMORY-DEAD-LINK`, `REF-CIRCULAR`, `HOOK-FAILING`, `EMBEDDED-SECRET`, `BAD-NAME`, `RESERVED-NAME`, `OUTPUTSTYLE-MISSING`, `SETTINGS-BYPASS-MODE`, `AGENT-BAD-SCHEMA`, `AGENT-BYPASS-PERMS`, `PLUGIN-MISPLACED-DIR`, `MARKETPLACE-DEAD-SOURCE`, `CLAUDEMD-DEAD-IMPORT`

**Structural** (works but should be reorganised)
`UNDER-TRIGGER`, `OVER-TRIGGER`, `MISSING-TRIGGER`, `MISSING-AGENT-TRIGGER`, `OVERLAPPING-AGENT`, `DUPLICATE-LOGIC`, `MISSING-ENFORCEMENT`, `NEEDS-REFERENCES`, `NO-EXAMPLES`, `NO-TROUBLESHOOTING`, `BURIED-CRITICAL`, `WEAK-DESC`, `NAME-MISMATCH`, `BAD-RULE-FRONTMATTER`, `ORPHAN-GUIDE`, `ORPHAN-PATTERN`, `REPURPOSE`, `SKILL-LOW-RELEVANCE`, `SKILL-DUPLICATE-DOMAIN`, `CLAUDEMD-STALE`, `CLAUDEMD-GENERIC`, `CLAUDEMD-THIN`, `SKILL-NEVER-FIRED`, `SKILL-DORMANT`, `SKILL-MISFIRING`, `RECURRING-DENIAL`, `SKILL-TOOL-UNDECLARED`, `HOOK-EVENT-MISMATCH`, `AGENT-NEVER-SPAWNED`, `AGENT-DUP-NAME`, `AGENT-PLUGIN-FORBIDDEN-FIELD`, `HOOK-EXIT-NONBLOCKING`, `HOOK-UNSAFE-SHELL`, `HOOK-ENV-LEAK`, `REF-TOO-DEEP`, `CONTEXT-BLOAT`, `PLUGIN-VERSION-DRIFT`, `PLUGIN-BAD-VERSION`, `PLUGIN-ABS-PATH`, `IMPORT-TOO-DEEP`, `DESCRIPTION-TOO-LONG`, `OVER-500-LINES`, `CHAINED-REF`, `NO-PROGRESSIVE-DISCLOSURE`, `DESCRIPTION-TRUNCATED`

**Hygiene** (cosmetic / token efficiency)
`BROAD-PATTERN`, `SUSPICIOUS-TIMEOUT`, `STALE-REMINDER`, `DUPLICATE-ENTRY`, `RULE-OVERSIZED`, `BODY-FILLER-HIGH`, `BODY-COMPRESSED`, `BODY-COMPRESSION-REJECTED`, `UNKNOWN-FRONTMATTER-FIELD`, `RECURRING-CORRECTION`, `SKILL-TOOL-UNUSED`, `PERM-DEAD-ENTRY`, `PERM-OVERBROAD`, `HOOK-NEVER-FIRED`, `REF-ORPHAN`, `MEMORY-ORPHAN-FILE`, `MEMORY-DUP-ENTRY`, `MEMORY-STALE-DATE`, `LOW-CACHE-HIT`, `UNFLAGGED-DESTRUCTIVE`, `THIRD-PERSON`, `MISSING-TOC`, `MCP-DEPRECATED-TRANSPORT`, `SETTINGS-MCP-AUTOAPPROVE`, `HOOK-NO-SHEBANG`, `LOCAL-MD-TRACKED`

**Discovery** (from Phase 4, additive only)
`NEW-RULE`, `NEW-PATTERN`, `NEW-TRIGGER`, `NEW-REFERENCE`, `SKILL-UPDATE`

`OBSERVATION` is not a tag — it's a free-text bucket for things the user should know that aren't actionable findings.

## Output Rules

- Render per `references/report-format.md`: a scorecard line, then findings grouped by DOMAIN (fixed order, omit empty domains), each a plain-language sentence with a `[must-fix]`/`[should]`/`[polish]` chip and the tag trailing as ` · TAG`.
- Scope is conveyed by a per-scope block header `## .claude health (user|project) — grade X`. Print one scorecard + grouped block per scope present. Do NOT prefix each finding line with the scope.
- Number findings 1…N globally in reading order (domain order, then chip severity within a domain) so the Phase 25 menu can reference "finding N" and "all must-fix".
- Empty domains and empty summary blocks MUST be omitted
- Output MUST NOT contain XML tags
- Every tag shown MUST be drawn from the canonical Tag Set; the tag is the trailing machine code and MUST NOT be dropped. The one exception: `[OBSERVATION]` lines carry no tag by definition (`OBSERVATION` is a free-text bucket, not a tag), so a judgment finding the grounding gate downgrades to an observation is correctly tag-less — this is not a dropped tag.
- Summary blocks (Plugin Integrity, Skill Usage, Reference Graph, Permission Hygiene, Hook Health, Auto-memory, Cross-session patterns, Context Trend) MUST be omitted when their phase produced no signal

## Pre-print pass — Verify, Ground & Self-check (MANDATORY before printing the report)

1. **Evidence-grounding gate (verify judgment findings).** Run every JUDGMENT finding through `finding-verification.md` BEFORE the checks below — it can drop or downgrade findings, so the later checks must operate on the final set. Deterministic / script-relayed findings (the `validate-skills.sh`, `scan-graph.sh`, and `scan-history.sh` tags listed in that doc) take the skip-verification fast path — they are already proof-backed and are NOT re-verified. For each surviving judgment finding, either attach an `Evidence:` locator (grounded), downgrade it to `[OBSERVATION]` (plausible but ungrounded), or drop it (disproven). Honour the `verifyFindings` config (default on); skip only when explicitly disabled. Resolve the spec the same way as `post-report-menu.md`: first that exists of `${CLAUDE_PLUGIN_ROOT}/commands/claude-markdown-health-check/references/finding-verification.md`, `~/.claude/claude-markdown-health-check/references/finding-verification.md`, or the repo copy.
2. **Tag canon enforcement** — every `[TAG]` in the draft MUST appear in the Tag Set above. For any tag that does not:
   - Relabel to the closest canonical tag
   - If no canonical tag fits, drop the finding rather than invent a new tag
3. **Scope enforcement** — every finding belongs to exactly one scope block, whose header states the scope (`## .claude health (user|project)`). No finding may appear outside a scope block.
4. **Single output channel** — confirm no Write/Edit tool calls were made to disk during this run. If one slipped through, list it under `[OBSERVATION] self-violation: wrote <path> against autonomy-gate rule` at the top.
5. **Privacy** — confirm no raw `cwd` paths or full session UUIDs from `history-scan.json` leaked into findings. Session IDs may appear as 8-char prefixes only.

Only after this self-check passes, print the report to chat.

## Phase 25 — Post-Report Menu

After the report prints, present an action menu instead of waiting passively. Read `post-report-menu.md` for menu options, apply rules, guardrails, and loop. Resolution: first that exists of `${CLAUDE_PLUGIN_ROOT}/commands/claude-markdown-health-check/references/post-report-menu.md`, `~/.claude/claude-markdown-health-check/references/post-report-menu.md`, or the repo copy.

Skip the menu only when the report has zero actionable findings — print a one-line all-clear and stop.
