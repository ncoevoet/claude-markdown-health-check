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
- Every `references/*.md` this command names resolves the same way — first that exists of `${CLAUDE_PLUGIN_ROOT}/references/<name>`, `~/.claude/markdown-health-check/references/<name>`, then the repo copy. Stated once here; the phases just name the file.
- Findings MUST be prefixed `[user]` or `[project]` so the user knows which tree the issue is in.
- Phase 5 runs `validate-skills.sh` once per scope. Phase 2/7/11/15/16/19/20/22/23 read the cached scan outputs.

## Stop Conditions (autonomy gate)

- After the report prints, run Phase 25 — present the post-report action menu. Do not apply any fix until the user picks a scope through it.
- NEVER edit, delete, move, or rename any file before the user picks a menu scope.
- NEVER write the report (or any copy / summary / "full version" of it) to disk. The chat channel is the only output. (Cache files at `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/{markdown-health-check-guidance,graph-scan,history-scan}.json` are internal state, NOT report content — those writes are explicitly allowed.)
- For `REPURPOSE` items: the destination `references/*.md` MUST be written and the SKILL.md References section MUST be updated BEFORE the source orphan is deleted.
- Done when: report printed in chat AND user has either named fixes OR explicitly declined further action.

## Phase 1 — Load Config + Thresholds

Full instructions: `references/command-phase-details.md` § "Phase 1 — Load Config + Thresholds" (read it before running this phase).

## Phase 2 — Plugin Install Integrity

Static check of `~/.claude/plugins/installed_plugins.json` vs the on-disk cache. Standard + Deep; skipped at Quick.

```bash
GRAPH="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}/graph-scan.json"
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/scripts/scan-graph.sh" "$USER_DIR" >/dev/null
jq -r '.findings[] | select(.phase == 2)' "$GRAPH"
```

See `plugin-integrity.md` for tag definitions (`PLUGIN-BROKEN-REF`, `PLUGIN-MISSING-MANIFEST`, `PLUGIN-VERSION-DRIFT`) and remediation order. The same phase-2 pass also flags deprecated MCP transport (`MCP-DEPRECATED-TRANSPORT`): an `mcpServers` entry of `"type":"sse"` in a location Claude Code loads (see `plugin-integrity.md`). It also flags a plugin installed at user scope but absent from `settings.json#enabledPlugins` (`PLUGIN-DISABLED`) — a parked plugin still consuming disk, a candidate for uninstall (the check is skipped entirely when no `enabledPlugins` map exists, so enable-state stays indeterminate rather than false-flagged, and a manifest carrying `defaultEnabled: false` is parked by design and exempt). The same pass flags a `dependencies` entry naming a plugin that is not installed → `PLUGIN-MISSING-DEPENDENCY`, and a plugin whose marketplace `settings.json` keeps from loading — listed in `blockedMarketplaces`, or unknown while `strictKnownMarketplaces` is on → `MARKETPLACE-BLOCKED`.

When the scanned tree is a **plugin root** (a `.claude-plugin/plugin.json` is present), the phase-2 pass also validates the plugin's own structure (any scope, so the tool dogfoods on plugin repos): a component dir (`skills`/`agents`/`commands`/`hooks`/`output-styles`/`monitors`/`workflows`/`themes`/`bin`) nested inside `.claude-plugin/` → `PLUGIN-MISPLACED-DIR`; a missing or non-semver `version` → `PLUGIN-BAD-VERSION`; a declared component path (`skills`, `commands`, `agents`, `outputStyles`, `lspServers`, `workflows`, `hooks`, `mcpServers`, `experimental.themes`, `experimental.monitors`) that isn't relative-with-`./` → `PLUGIN-ABS-PATH`, with the documented `skills: "."` exception exempt; a hook or monitor command interpolating `${user_config.…}`, which Claude Code rejects outside skill/agent bodies and MCP/LSP `env` → `PLUGIN-USERCONFIG-IN-SHELL`; a **local** `marketplace.json` plugin `source` that resolves to no directory → `MARKETPLACE-DEAD-SOURCE` (remote `http`/`git@`/`npm:`/`github:`/`git:` sources are not paths and are skipped).

The pass also runs on a **marketplace-only root** (a `.claude-plugin/marketplace.json` with no `plugin.json`, like this tool's own repo root). It validates plugin and marketplace NAMES (`PLUGIN-RESERVED-NAME`, `PLUGIN-NAME-LOOKALIKE`, `PLUGIN-NAME-FORMAT`, `PLUGIN-NAME-NOT-KEBAB`, `MARKETPLACE-NAME-FORMAT`, `MARKETPLACE-NAME-RESERVED`), manifest keys and paths (`PLUGIN-UNKNOWN-KEY`, `PLUGIN-STRICT-OBJECT-UNKNOWN-KEY`, `MARKETPLACE-UNKNOWN-KEY`, `PLUGIN-DEFAULT-DIR-SHADOWED`, `PLUGIN-PATH-ESCAPE`), the plugin's eval suite (`EVAL-CASE-NO-GRADER`, `EVAL-NO-SKILL-GRADER`, `PLUGIN-NO-EVALS`) and MCP placement (`MCP-MISPLACED`, `MCP-RELATIVE-PATH`). All are relay-only.

## Phase 3 — Select Depth

Full instructions: `references/command-phase-details.md` § "Phase 3 — Select Depth" (read it before running this phase).

## Phase 4 — Read Focus + History

Full instructions: `references/command-phase-details.md` § "Phase 4 — Read Focus + History" (read it before running this phase).

## Phase 5 — Run validate-skills.sh (per scope)

Full instructions: `references/command-phase-details.md` § "Phase 5 — Run validate-skills.sh (per scope)" (read it before running this phase).

## Phase 6 — Skill Listing Budget

Full instructions: `references/command-phase-details.md` § "Phase 6 — Skill Listing Budget" (read it before running this phase).

## Phase 7 — Skill Usage Metrics

Full instructions: `references/command-phase-details.md` § "Phase 7 — Skill Usage Metrics" (read it before running this phase).

## Phase 8 — Skill Semantic Audit

Full instructions: `references/command-phase-details.md` § "Phase 8 — Skill Semantic Audit" (read it before running this phase).

## Phase 9 — Skill–Tool Contract

Full instructions: `references/command-phase-details.md` § "Phase 9 — Skill–Tool Contract" (read it before running this phase).

## Phase 10 — Frontmatter Strict Schema

Full instructions: `references/command-phase-details.md` § "Phase 10 — Frontmatter Strict Schema" (read it before running this phase).

## Phase 11 — Reference Graph Health

Full instructions: `references/command-phase-details.md` § "Phase 11 — Reference Graph Health" (read it before running this phase).

## Phase 12 — CLAUDE.md Content Quality

Full instructions: `references/command-phase-details.md` § "Phase 12 — CLAUDE.md Content Quality" (read it before running this phase).

## Phase 13 — Body Compression (detection + opt-in rewrite)

Full instructions: `references/command-phase-details.md` § "Phase 13 — Body Compression (detection + opt-in rewrite)" (read it before running this phase).

## Phase 14 — Hooks, Agents, Settings

Full instructions: `references/command-phase-details.md` § "Phase 14 — Hooks, Agents, Settings" (read it before running this phase).

## Phase 15 — Permission Allowlist Hygiene

Full instructions: `references/command-phase-details.md` § "Phase 15 — Permission Allowlist Hygiene" (read it before running this phase).

## Phase 16 — Hook Latency + Reliability

Full instructions: `references/command-phase-details.md` § "Phase 16 — Hook Latency + Reliability" (read it before running this phase).

## Phase 17 — Cross-references and Orphans

Full instructions: `references/command-phase-details.md` § "Phase 17 — Cross-references and Orphans" (read it before running this phase).

## Phase 18 — Orphan Repurposing

Full instructions: `references/command-phase-details.md` § "Phase 18 — Orphan Repurposing" (read it before running this phase).

## Phase 19 — Cross-Session Pattern Mining (Deep only)

Full instructions: `references/command-phase-details.md` § "Phase 19 — Cross-Session Pattern Mining (Deep only)" (read it before running this phase).

## Phase 20 — Auto-memory Hygiene

Full instructions: `references/command-phase-details.md` § "Phase 20 — Auto-memory Hygiene" (read it before running this phase).

## Phase 21 — Name Collisions

Full instructions: `references/command-phase-details.md` § "Phase 21 — Name Collisions" (read it before running this phase).

## Phase 22 — Agents Never-Spawned

Full instructions: `references/command-phase-details.md` § "Phase 22 — Agents Never-Spawned" (read it before running this phase).

## Phase 23 — Token Trend (Deep only)

Full instructions: `references/command-phase-details.md` § "Phase 23 — Token Trend (Deep only)" (read it before running this phase).

## Phase 26 — Output Styles

Full instructions: `references/command-phase-details.md` § "Phase 26 — Output Styles" (read it before running this phase).

## Phase 27 — Context Coherence

Full instructions: `references/command-phase-details.md` § "Phase 27 — Context Coherence" (read it before running this phase).

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
1. 🔴 must-fix <plain-language problem>                          · TAG
```

### Full Report (Standard / Deep)

Render per `references/report-format.md`: a scorecard, then findings grouped by
DOMAIN (not by severity tier), each a plain-language sentence with a
`🔴 must-fix`/`🟠 should`/`🟡 polish` chip and the tag trailing as a machine code.
One scorecard + grouped block per scope present.

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
 N. 🔴 must-fix <plain-language problem>
               <path/locator>                                   · TAG

### Suggestions                           ← Discovery 🔵 idea items, omit if none
 N. 🔵 idea <plain-language suggestion>                          · TAG

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
 1. 🔴 must-fix atlassian links to a missing file (skills/atlassian/references/api.md)
               skills/atlassian/SKILL.md                          · DEAD-REF
 2. 🟠 should   atlassian body is 412 lines with no references/ split
               skills/atlassian/SKILL.md                   · NEEDS-REFERENCES
 3. 🟠 should   atlassian is unused in the last 30 days but loads 4.2k chars per session
               skills/atlassian                               · SKILL-DORMANT

## Hooks
 4. 🔴 must-fix the Edit hook fails on almost every run (284/304, 93%)
               PreToolUse:Edit                                  · HOOK-FAILING

## Settings & Permissions
 5. 🟡 polish   Bash(cat:*) lets any file be read — scope it to ~/.claude
               settings.json                                   · BROAD-PATTERN
```

## Tag Set (canonical — MUST be drawn from this list)

**Critical** (broken; blocks correct behaviour)
`DEAD-REF`, `DUPLICATE-KEY`, `INVALID-JSON`, `MISSING-DESC`, `DEAD-MATCHER`, `UNREGISTERED-HOOK`, `MISSING-PRE-APPROVED`, `MEMORY-OVERFLOW`, `SKILL-BUDGET-OVERFLOW`, `STALE-THRESHOLD`, `GUIDANCE-FETCH-FAILED`, `BAD-FRONTMATTER-SCHEMA`, `NAME-COLLISION`, `SKILL-ORPHAN`, `MISSING-SKILL-GAP`, `PLUGIN-BROKEN-REF`, `PLUGIN-MISSING-MANIFEST`, `MEMORY-DEAD-LINK`, `REF-CIRCULAR`, `HOOK-FAILING`, `EMBEDDED-SECRET`, `BAD-NAME`, `RESERVED-NAME`, `OUTPUTSTYLE-MISSING`, `SETTINGS-BYPASS-MODE`, `AGENT-BAD-SCHEMA`, `AGENT-BYPASS-PERMS`, `PLUGIN-MISPLACED-DIR`, `MARKETPLACE-DEAD-SOURCE`, `CLAUDEMD-DEAD-IMPORT`, `CLAUDEMD-DEAD-SCRIPT`, `MARKETPLACE-BLOCKED`, `DESC-XML-TAG`, `HOOK-MATCHER-ARRAY`, `AGENT-YAML-UNPARSED`, `MCP-MISPLACED`, `MARKETPLACE-NAME-FORMAT`, `MARKETPLACE-NAME-RESERVED`, `PLUGIN-STRICT-OBJECT-UNKNOWN-KEY`, `PLUGIN-PATH-ESCAPE`

**Structural** (works but should be reorganised)
`UNDER-TRIGGER`, `OVER-TRIGGER`, `MISSING-TRIGGER`, `MISSING-AGENT-TRIGGER`, `OVERLAPPING-AGENT`, `DUPLICATE-LOGIC`, `MISSING-ENFORCEMENT`, `NEEDS-REFERENCES`, `RULE-CONFLICT`, `BURIED-CRITICAL`, `WEAK-DESC`, `NAME-MISMATCH`, `BAD-RULE-FRONTMATTER`, `ORPHAN-GUIDE`, `ORPHAN-PATTERN`, `REPURPOSE`, `SKILL-LOW-RELEVANCE`, `SKILL-DUPLICATE-DOMAIN`, `CLAUDEMD-STALE`, `CLAUDEMD-GENERIC`, `CLAUDEMD-THIN`, `SKILL-NEVER-FIRED`, `SKILL-DORMANT`, `SKILL-MISFIRING`, `RECURRING-DENIAL`, `SKILL-TOOL-UNDECLARED`, `HOOK-EVENT-MISMATCH`, `AGENT-NEVER-SPAWNED`, `AGENT-DUP-NAME`, `AGENT-PLUGIN-FORBIDDEN-FIELD`, `HOOK-EXIT-NONBLOCKING`, `HOOK-UNSAFE-SHELL`, `HOOK-ENV-LEAK`, `REF-TOO-DEEP`, `CONTEXT-BLOAT`, `PLUGIN-VERSION-DRIFT`, `PLUGIN-BAD-VERSION`, `PLUGIN-ABS-PATH`, `MCP-BAD-DEF`, `MODEL-NOT-AVAILABLE`, `IMPORT-TOO-DEEP`, `DESCRIPTION-TOO-LONG`, `OVER-500-LINES`, `CHAINED-REF`, `NO-PROGRESSIVE-DISCLOSURE`, `DESCRIPTION-TRUNCATED`, `MEMORY-STALE-CONTENT`, `HOOK-HTTP-BLOCKED`, `PLUGIN-USERCONFIG-IN-SHELL`, `PLUGIN-MISSING-DEPENDENCY`, `NO-UNIQUE-ANCHOR`, `ANCHOR-COLLISION`, `SKILL-LOW-OBSERVED-RECALL`, `WINDOWS-PATH`, `HOOK-MATCHER-CASE`, `HOOK-MATCHER-BARE-MCP`, `SETTINGS-SCOPE-IGNORED`, `WORKTREE-SPARSE-NO-CLAUDE`, `PERM-INERT-RULE`, `OUTPUTSTYLE-CASE`, `OUTPUTSTYLE-BAD-YAML`, `PLUGIN-RESERVED-NAME`, `PLUGIN-NAME-FORMAT`, `EVAL-CASE-NO-GRADER`

**Hygiene** (cosmetic / token efficiency)
`BROAD-PATTERN`, `SUSPICIOUS-TIMEOUT`, `STALE-REMINDER`, `DUPLICATE-ENTRY`, `RULE-OVERSIZED`, `BODY-FILLER-HIGH`, `BODY-COMPRESSED`, `BODY-COMPRESSION-REJECTED`, `UNKNOWN-FRONTMATTER-FIELD`, `RECURRING-CORRECTION`, `SKILL-TOOL-UNUSED`, `PERM-DEAD-ENTRY`, `PERM-OVERBROAD`, `HOOK-NEVER-FIRED`, `REF-ORPHAN`, `MEMORY-ORPHAN-FILE`, `MEMORY-DUP-ENTRY`, `MEMORY-STALE-DATE`, `LOW-CACHE-HIT`, `UNFLAGGED-DESTRUCTIVE`, `THIRD-PERSON`, `MISSING-TOC`, `MCP-DEPRECATED-TRANSPORT`, `MCP-PLAINTEXT-SECRET`, `SETTINGS-MCP-AUTOAPPROVE`, `HOOK-NO-SHEBANG`, `LOCAL-MD-TRACKED`, `PLUGIN-DISABLED`, `OVER-CONSTRAINED`, `INSTRUCTION-DUPLICATED`, `CLAUDEMD-OBVIOUS`, `CLAUDEMD-MEMORY-DRIFT`, `SETTINGS-SANDBOX-OFF`, `SETTINGS-AUTOMODE-BROAD`, `ANCHOR-NOT-STATED`, `DESC-TOO-SHORT`, `TIME-SENSITIVE`, `VAGUE-NAME`, `RESERVED-WORD-PORTABILITY`, `SETTINGS-DEPRECATED-KEY`, `CLAUDEMD-EXCLUDE-DEAD`, `CLAUDEIGNORE-NO-EFFECT`, `SKILL-COMPACTION-TRUNCATED`, `MCP-RELATIVE-PATH`, `OUTPUTSTYLE-UNKNOWN-FIELD`, `OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN`, `PLUGIN-NAME-LOOKALIKE`, `PLUGIN-NAME-NOT-KEBAB`, `PLUGIN-DEFAULT-DIR-SHADOWED`, `PLUGIN-UNKNOWN-KEY`, `MARKETPLACE-UNKNOWN-KEY`, `EVAL-NO-SKILL-GRADER`

**Discovery** (from Phase 4, additive only)
`NEW-RULE`, `NEW-PATTERN`, `NEW-TRIGGER`, `NEW-REFERENCE`, `SKILL-UPDATE`, `SKILL-NETWORK-SURFACE`, `SKILL-HIDDEN-BEHAVIOR`, `SKILL-MCP-REFERENCE`, `RULE-PATH-LOST-ON-COMPACT`, `PLUGIN-NO-EVALS`

`OBSERVATION` is not a tag — it's a free-text bucket for things the user should know that aren't actionable findings.

## Output Rules

- Rendering is Phase 24's job (`references/report-format.md`) — it is not restated here.
- Scope is conveyed by the per-scope block header `## .claude health (user|project) — grade X`; do NOT prefix each finding line with the scope.
- Number findings 1…N globally in reading order (domain order, then chip severity within a domain) so the Phase 25 menu can reference "finding N" and "all must-fix".
- Empty domains and empty summary blocks MUST be omitted
- Output MUST NOT contain XML tags
- Every tag shown MUST be drawn from the canonical Tag Set; the tag is the trailing machine code and MUST NOT be dropped. The one exception: `[OBSERVATION]` lines carry no tag by definition (`OBSERVATION` is a free-text bucket, not a tag), so a judgment finding the grounding gate downgrades to an observation is correctly tag-less — this is not a dropped tag.
- Summary blocks (Plugin Integrity, Skill Usage, Reference Graph, Permission Hygiene, Hook Health, Auto-memory, Cross-session patterns, Context Trend) MUST be omitted when their phase produced no signal

## Pre-print pass — Verify, Ground & Self-check (MANDATORY before printing the report)

1. **Evidence-grounding gate (verify judgment findings).** Run every JUDGMENT finding through `finding-verification.md` BEFORE the checks below — it can drop or downgrade findings, so the later checks must operate on the final set. Deterministic / script-relayed findings (the `validate-skills.sh`, `scan-graph.sh`, and `scan-history.sh` tags listed in that doc) take the skip-verification fast path — they are already proof-backed and are NOT re-verified. For each surviving judgment finding, either attach an `Evidence:` locator (grounded), downgrade it to `[OBSERVATION]` (plausible but ungrounded), or drop it (disproven). Honour the `verifyFindings` config (default on); skip only when explicitly disabled.
2. **Tag canon enforcement** — every `[TAG]` in the draft MUST appear in the Tag Set above. For any tag that does not:
   - Relabel to the closest canonical tag
   - If no canonical tag fits, drop the finding rather than invent a new tag
3. **Scope enforcement** — every finding belongs to exactly one scope block, whose header states the scope (`## .claude health (user|project)`). No finding may appear outside a scope block.
4. **Single output channel** — confirm no Write/Edit tool calls were made to disk during this run. If one slipped through, list it under `[OBSERVATION] self-violation: wrote <path> against autonomy-gate rule` at the top.
5. **Privacy** — confirm no raw `cwd` paths or full session UUIDs from `history-scan.json` leaked into findings. Session IDs may appear as 8-char prefixes only.

Only after this self-check passes, print the report to chat.

## Phase 25 — Post-Report Menu

After the report prints, present an action menu instead of waiting passively. Read `post-report-menu.md` for menu options, apply rules, guardrails, and loop.

Skip the menu only when the report has zero actionable findings — print a one-line all-clear and stop.
