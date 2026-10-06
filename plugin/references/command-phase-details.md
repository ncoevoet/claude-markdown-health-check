# Command Phase Details

Phase instructions moved out of `commands/markdown-health-check.md` to keep the command under 500 lines and 5,000 tokens. Each phase heading below matches the one in the command file; follow the instructions verbatim.

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
CACHE="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}/markdown-health-check-guidance.json"
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
- https://code.claude.com/docs/en/settings-reference
- https://code.claude.com/docs/en/plugins/manifest-reference

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

Note: hook `timeout` defaults differ per type and event — `command`/`http`/`mcp_tool` default to 600s, except 30s on `UserPromptSubmit`, `PreModelSwitch` and `PostModelSwitch` and 10s on `MessageDisplay`; `prompt` 30s; `agent` 60s; `SessionEnd` is capped at 60s. `validate-skills.sh` accounts for all of this in `SUSPICIOUS-TIMEOUT`.

## Phase 3 — Select Depth
```bash
SKILLS=$(ls "$USER_DIR"/skills/*/SKILL.md ${PROJECT_DIR:+"$PROJECT_DIR"/skills/*/SKILL.md} 2>/dev/null | wc -l)
```

| Depth | Trigger | Phases |
|-------|---------|--------|
| Quick | user said `quick` (never auto-selected) | 1, 5, 6, 10, 21, 24, 25 + spot-check 3 highest-risk skills |
| Standard | default | 1–18, 20, 24, 25, 27 |
| Deep | user said `deep` / `comprehensive`, OR `$SKILLS>20` | 1–27 (full) |

Quick is opt-in only. Auto-selecting it for a small tree silently returned a
partial audit to exactly the users least able to notice phases were missing;
the automatic Standard→Deep upgrade stays, because widening coverage is not a
surprise worth guarding against.

`--window-days=N` overrides the 30-day default used by Phases 7, 9, 15, 16, 19, 22, 23. When no `quick`/`deep` arg is given, the `depth` config key (`config-keys.md`) sets the floor; `SKIP_PHASES` (config) then removes any listed phases from the selected set — except Phase 5, which always runs.

## Phase 4 — Read Focus + History
**If the user passed a focus message** (anything that is not `quick`/`deep`/`--refresh`/`--compress-bodies`/`--window-days=*`):
1. Treat it as the #1 priority. Tag findings related to it as `NEW-RULE`, `NEW-PATTERN`, or `SKILL-UPDATE`.
2. Search whether the topic is already covered in any guide, pattern, skill, or CLAUDE.md rule. If not, flag it.
3. List every place the rule SHOULD be propagated (MEMORY.md, critical-rules.md, relevant patterns, SKILL.md files, hooks).
4. Scan recent conversation changes for violations and flag them.

**Conversation history** (always):
- "Empty" means: zero user/assistant turns BEFORE this `/markdown-health-check` invocation in the current session. The command itself does NOT count as history. If empty, the report MUST include `[OBSERVATION] empty-history: skipping behavioural analysis` — mandatory output.
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

# Anchor tokens feed Phase 7's observed-recall join (scan-history.sh --anchors-file).
# A scope = one validate-skills.sh invocation, so merge the USER_DIR + PROJECT_DIR
# anchor tables here (Change 1's --anchors is per-scope by design) — transcripts
# under ~/.claude/projects are never scope-partitioned, so the join needs one
# combined table. Fails open at every step: --anchors itself prints "{}" when jq
# is missing or a scope has no skills (never a non-zero exit), and if jq isn't
# available here either, ANCHORS_FILE stays empty and Phase 7 simply runs without
# it (observedRecall == {}), same as today.
ANCHORS_FILE=""
if command -v jq >/dev/null 2>&1; then
    ANCHORS_CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}"
    mkdir -p "$ANCHORS_CACHE_DIR" 2>/dev/null
    ANCHORS_CANDIDATE="$ANCHORS_CACHE_DIR/anchors-merged.json"
    if { bash "$VALIDATE" --anchors "$USER_DIR" 2>/dev/null
         [[ -n "$PROJECT_DIR" ]] && bash "$VALIDATE" --anchors "$PROJECT_DIR" 2>/dev/null
       } | jq -s 'add // {}' >"$ANCHORS_CANDIDATE" 2>/dev/null \
      && [[ -s "$ANCHORS_CANDIDATE" ]]; then
        ANCHORS_FILE="$ANCHORS_CANDIDATE"
    fi
fi
```

This is the deterministic layer. Trust its output for: name regex, the reserved `synced` skill folder, name/dir mismatch, missing descriptions, voice violations, line counts, chained references, dead links (skill `references/*.md`, settings `guides`, CLAUDE.md `.claude/…` paths), JSON validity, duplicate keys and array entries, MCP pre-approval, unregistered hooks, hook timeouts, memory-index size, rule scoping, TOC presence, description sizes, frontmatter schema (`model` whitelist, `allowed-tools` syntax), unknown frontmatter fields, hook matcher shape (`HOOK-MATCHER-ARRAY`, `HOOK-MATCHER-CASE`, `HOOK-MATCHER-BARE-MCP`), settings scope/deprecation and inert permission rules (`SETTINGS-SCOPE-IGNORED`, `SETTINGS-DEPRECATED-KEY`, `CLAUDEMD-EXCLUDE-DEAD`, `WORKTREE-SPARSE-NO-CLAUDE`, `PERM-INERT-RULE`, `CLAUDEIGNORE-NO-EFFECT`), unparseable agent YAML and truncated-on-compaction skills (`AGENT-YAML-UNPARSED`, `SKILL-COMPACTION-TRUNCATED`), plugin-skill risk indicators (`SKILL-NETWORK-SURFACE`, `SKILL-HIDDEN-BEHAVIOR`, `SKILL-MCP-REFERENCE`, `RULE-PATH-LOST-ON-COMPACT`), name collisions between `commands/` and `skills/`, embedded credentials in skill/reference markdown (`EMBEDDED-SECRET`), destructive shell commands without nearby warning markers (`UNFLAGGED-DESTRUCTIVE`), the context-engineering set relayed by Phases 12 and 27 (`OVER-CONSTRAINED`, `INSTRUCTION-DUPLICATED`, `CLAUDEMD-OBVIOUS`, `CLAUDEMD-MEMORY-DRIFT`), anchor-token analysis over description + when_to_use (`NO-UNIQUE-ANCHOR`, `ANCHOR-COLLISION`, `ANCHOR-NOT-STATED`), and the Agent Skills best-practices checks: XML tags in descriptions, Windows-style paths, time-sensitive wording, vague names, reserved words (portability). Later phases MUST NOT re-check anything this script already covers — they MUST only handle what the script can't.

## Phase 6 — Skill Listing Budget
Audits whether the cumulative skill-listing block fits Claude Code's runtime budget. Emits `SKILL-BUDGET-OVERFLOW` (Critical) plus `SKILL-LOW-RELEVANCE` and `SKILL-DUPLICATE-DOMAIN` (Structural). See `skill-listing-budget.md` for the full logic, the `validate-skills.sh --listing-cost` invocation, and the remediation order.

## Phase 7 — Skill Usage Metrics
Cross-session invocation, dormancy, and orphan detection over the 30-day window. Standard + Deep.

```bash
HIST="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}/history-scan.json"
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/scripts/scan-history.sh" \
    ${WINDOW:+--window-days "$WINDOW"} \
    ${ANCHORS_FILE:+--anchors-file "$ANCHORS_FILE"} >/dev/null
```

`ANCHORS_FILE` is set (or left empty) by Phase 5. Passing it is what makes `.observedRecall` non-empty — without it every anchor-bearing prompt in the transcripts still gets scanned for other signals, but the observed-recall join never runs and `SKILL-LOW-OBSERVED-RECALL` can never fire.

See `skill-usage-metrics.md` for the heuristic formulas and tag definitions (`SKILL-NEVER-FIRED`, `SKILL-DORMANT`, `SKILL-MISFIRING`, `SKILL-ORPHAN`, `SKILL-LOW-OBSERVED-RECALL`). Findings reference skill names only; wording must say "in this install" since `.skillUsage` is per-machine.

## Phase 8 — Skill Semantic Audit
For each skill under `$USER_DIR/skills/*/SKILL.md` AND `$PROJECT_DIR/skills/*/SKILL.md` (when set) — the script handles deterministic checks; this phase handles judgment calls:

**Description quality**
- Description MUST follow `[What it does] + [When to use] + [Key capabilities]` shape — flag `WEAK-DESC` if the "when to use" half is missing or generic.
- Description triggers MUST match real usage. Compare keywords in `description` + `when_to_use` against CLAUDE.md "Skills" table:
  - Skill handles cases CLAUDE.md doesn't list → `UNDER-TRIGGER`
  - CLAUDE.md lists triggers the skill doesn't actually handle → `OVER-TRIGGER`

**Structure quality**
- SKILL.md > `skillMd.maxLines × 0.6` lines AND no `references/` subdir → `NEEDS-REFERENCES`
- Critical instructions buried below line 50 → `BURIED-CRITICAL`
- A missing "Examples" or "Troubleshooting" section is NOT a finding. Worked examples pin the model to the shape they show; a skill earns its place through an expressive interface (clear parameters, named states, honest tool descriptions), not through sample transcripts. Flag a thin skill on what it fails to say, never on a section it omits.

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
- A command, path, or version CLAUDE.md states that the codebase contradicts → `CLAUDEMD-STALE`. This includes a **self-referential count** the referenced file contradicts — "all N rules", "N modules", "N steps" where the cited file actually holds a different number (e.g. CLAUDE.md says "all 36 rules" but `critical-rules.md` defines 41).
- Generic boilerplate not specific to this repo → `CLAUDEMD-GENERIC`
- No build/test/run commands, or no architecture map → `CLAUDEMD-THIN`

Then compute the **per-file CLAUDE.md score** (always-on; see the rubric in `claude-md-quality.md`) from the surviving findings and render it per `report-format.md`.

Skip at Quick depth. A short but accurate CLAUDE.md is not a finding.

Two more judgment-free relays land here from Phase 5, both from the Claude 5 context-engineering guidance: a block of ≥6 consecutive bare path lines whose entries resolve on disk → `CLAUDEMD-OBVIOUS` (the file tree is one tool call away; the budget belongs to the gotchas), and ≥3 memory-shaped bullets — "Remember …", "The user prefers …", anything under a *Notes to self* / *Memories* heading → `CLAUDEMD-MEMORY-DRIFT` (auto-memory owns those now, and keeps them out of every-turn context). An annotated architecture map, where each entry carries a relationship or a quirk, is not a listing — it is exactly what the file should hold.

Deterministic CLAUDE.md checks run inside `validate-skills.sh` (Phase 5) and relay here: a `npm run <script>` mention (in CLAUDE.md, `CLAUDE.local.md`, or a `documentation/guides/*.md` it routes to) whose `<script>` is defined in no `package.json` from the file up to the repo root → `CLAUDEMD-DEAD-SCRIPT`; an `@path` import that does not resolve → `CLAUDEMD-DEAD-IMPORT`; an `@import` chain deeper than the 4-hop limit → `IMPORT-TOO-DEEP`; a `CLAUDE.local.md` inside a git repo with no covering `.gitignore` entry → `LOCAL-MD-TRACKED`. See `claude-md-quality.md`.

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
- `validate-skills.sh` statically scans hook scripts and http hook config (see `references/hook-safety.md`) → hook script with no `#!` shebang → `HOOK-NO-SHEBANG`; a script that emits a block/deny decision but exits 1 instead of 2 (exit 1 is non-blocking) → `HOOK-EXIT-NONBLOCKING`; `eval` of a dynamic value → `HOOK-UNSAFE-SHELL`; an http hook with an auth header but no `allowedEnvVars`/`httpHookAllowedEnvVars` → `HOOK-ENV-LEAK`; an http hook whose `url` matches no `allowedHttpHookUrls` pattern, so Claude Code blocks it and it never runs → `HOOK-HTTP-BLOCKED` — relay.
- Two hooks doing the same check → `DUPLICATE-LOGIC`
- Critical rule with no hook enforcement and a deterministic check exists → `MISSING-ENFORCEMENT`
- `validate-skills.sh` also statically checks hook matchers and relays: a matcher given as an array → `HOOK-MATCHER-ARRAY`; a tool-event matcher segment starting lower-case (tool names are case-sensitive) → `HOOK-MATCHER-CASE`; a bare `mcp__server` matcher that is not a regex → `HOOK-MATCHER-BARE-MCP` — relay.
- Matcher pattern doesn't match any real tool name → `DEAD-MATCHER`. NEVER emit `DEAD-MATCHER` for a matcher the script already reports as `HOOK-MATCHER-ARRAY`, `HOOK-MATCHER-CASE` or `HOOK-MATCHER-BARE-MCP`; `DEAD-MATCHER` stays the judgment tag for a regex-path matcher that names no real tool, so nothing is double-reported. ONLY for tool-events (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied`) whose matcher IS a tool name. For event-typed matchers the matcher is an event-specific string, NOT a tool — never flag those: `SessionStart` (`startup|resume|clear|compact`), `PreCompact`/`PostCompact` (`manual|auto`), `SessionEnd`, `Notification`, `SubagentStart`/`SubagentStop`, `ConfigChange`, etc. See `references/hook-reliability.md` for the event→matcher table

**Agents** (`.claude/agents/*.md`)
- `validate-skills.sh` validates every subagent file against the subagent schema (distinct from the skill schema — see `references/agent-frontmatter.md`) and relays: bad `model`/`color`/`permissionMode` value, malformed `tools`/`disallowedTools`, missing `description`, or bad `name` charset → `AGENT-BAD-SCHEMA`; `permissionMode: bypassPermissions` → `AGENT-BYPASS-PERMS`; two agent files sharing a `name` → `AGENT-DUP-NAME`; a plugin-tree agent declaring `hooks`/`mcpServers`/`permissionMode` (silently ignored) → `AGENT-PLUGIN-FORBIDDEN-FIELD` — relay.
- Agent description triggers MUST be reachable from CLAUDE.md → `MISSING-AGENT-TRIGGER`
- Two agents covering the same problem space with no differentiation → `OVERLAPPING-AGENT`

**Settings (`settings.json`)**
- `validate-skills.sh` flags malformed JSON → `INVALID-JSON`, duplicate keys → `DUPLICATE-KEY`, duplicate array entries → `DUPLICATE-ENTRY`, MCP servers absent from `preApprovedTools`/`permissions.allow` → `MISSING-PRE-APPROVED`, `defaultMode: bypassPermissions` → `SETTINGS-BYPASS-MODE`, `enableAllProjectMcpServers: true` → `SETTINGS-MCP-AUTOAPPROVE`, `sandbox.disabled: true` → `SETTINGS-SANDBOX-OFF`, a whole-tool wildcard in `autoMode.allow` → `SETTINGS-AUTOMODE-BROAD` — relay. `SETTINGS-BYPASS-MODE` is Critical only at user scope; at project/local scope the script downgrades it to a warning.
- Also relay-only from the script: a key set in a scope that ignores it → `SETTINGS-SCOPE-IGNORED`; a removed or deprecated key → `SETTINGS-DEPRECATED-KEY`; a `claudeMdExcludes` pattern that is relative or matches nothing → `CLAUDEMD-EXCLUDE-DEAD`; `worktree.sparsePaths` omitting `.claude` → `WORKTREE-SPARSE-NO-CLAUDE`; a permission rule Claude Code never consults or skips → `PERM-INERT-RULE`; a `.claudeignore` file, which Claude Code does not read → `CLAUDEIGNORE-NO-EFFECT`. Report them as emitted; do not re-judge.
- Intent-judgment indicators (Discovery, from the script): `SKILL-MCP-REFERENCE` (a skill names `Server:tool_name`) — judge whether the skill's stated purpose needs that server; `RULE-PATH-LOST-ON-COMPACT` (a hard directive inside a path-scoped rule, which is reloaded after `/compact` only when a matching file is read again) — relay as `🔵 idea`. Any "directives in the last third of a file get ignored" reading is an undocumented heuristic: label it as such in prose and emit no tag for it.
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

**Content grounding (Standard + Deep) → `MEMORY-STALE-CONTENT` (Structural).** Beyond the link-index, catch a memory body asserting something the tree now contradicts. Two slices: the **deterministic** slice — a body citing a missing `.claude/…` path — is relayed from `validate-skills.sh` (Phase 5), no re-grounding. The **judgment** slice — a body asserting a behaviour the code disproves (e.g. "pre-commit runs vitest+prettier" when `.husky/pre-commit` runs prettier only) — runs through the Pre-print grounding gate and survives only with a quotable contradicting artifact AND the described project actually on disk to read; otherwise abstain (no flag). Ground ONLY claims naming a concrete artifact; skip pure prose/preference memories. See `memory-hygiene.md`.

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

See `output-styles.md` for the tag definition: `OUTPUTSTYLE-MISSING` (Critical — `outputStyle` names a non-existent, non-built-in style). Built-in styles are exactly `Default`, `Proactive`, `Concise`, `Explanatory`, `Learning` (case-sensitive; lower-case `default` is tolerated) and have no file. A style is named by its frontmatter `name:`, else its file name; styles resolve from the scanned tree, the user tree, ancestor `.claude/output-styles/` up to the repo root, manifest `outputStyles` paths and installed plugins. Related tags: `OUTPUTSTYLE-CASE`, `OUTPUTSTYLE-UNKNOWN-FIELD`, `OUTPUTSTYLE-BAD-YAML`, `OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN`. There is no "orphan style" tag — unselected style files are a legitimate palette, not a defect.

## Phase 27 — Context Coherence
Judges the assembled context — CLAUDE.md and its imports, skills, commands, rules, output styles — as the single document the model actually reads. Standard + Deep. See `context-coherence.md` for thresholds, calibration, and remediation.

- `OVER-CONSTRAINED` (Hygiene) and `INSTRUCTION-DUPLICATED` (Hygiene) relay from Phase 5 — deterministic, no re-checking.
- `RULE-CONFLICT` (Structural) is the judgment check: two directives a single request cannot satisfy at once. It survives the Pre-print grounding gate only with both sides quoted, file and line each.
