# Finding Verification — evidence-grounding gate

Loaded by `/claude-markdown-health-check` as **step 1 of the Pre-print pass**
(before tag-canon enforcement). Filters the JUDGMENT findings — the ones the LLM
phases reason out (Phases 6, 8, 12, 14, 17, 18, 19) — so the report carries only
findings provable from a concrete artifact. Deterministic / script-relayed
findings skip this gate entirely.

This is the health-check analogue of review-all's Phase 2.5 verifier, adapted to a
single-pass linear audit over a SMALL `.claude/` tree: there is no subagent and no
per-finding spawn — the main agent re-reads inline, in parallel.

Honour `verifyFindings` (config, default `true`). When set `false`, skip this gate
entirely and emit judgment findings unverified — a debugging escape hatch only.

## Contents
- Stance
- Skip-verification fast path (deterministic tags)
- Evidence required per judgment tag
- Disproof checklist
- Outcome: keep / downgrade / drop
- Self-check

## Stance — adversarial auditor, not confirmatory

**Assume every JUDGMENT finding is a false positive until grounded in concrete
evidence you can quote.** Your job is to find the specific reason each judgment
finding does NOT hold. Only when you exhaust the checks below without a disproof do
you keep it.

This is deliberate. An auditor that trusts its own first-pass judgment inflates
false positives — it flags a guide as orphaned without re-running the grep, calls a
CLAUDE.md command stale without checking the path exists, or labels a description
"weak" on vibe. Hostile re-grounding produces a quieter, trustworthy report. A user
who gets one wrong `[must-fix]` stops trusting all of them.

Be hostile to the **finding, not to the tree.** You are prosecuting the claim
("prove this specific defect is real on disk") — not hunting the tree for new
faults. Do NOT invent additional findings, escalate severity, or audit files the
finding does not name. Adjudicate only the finding in front of you.

The primary disproof is the **evidence gate**: a judgment finding survives only if
you can show the concrete artifact that exhibits the defect — a quoted line, a
resolved-or-missing path, a metric from a scan cache. A finding you cannot ground in
a citable artifact is a false positive, however plausible it reads.

## Skip-verification fast path (deterministic tags)

A finding SKIPS this gate (auto-keep, no re-verification) when it was **emitted or
relayed from a deterministic scanner**. The tool is the proof. These tags are
script-owned — the orchestrator only relays them; never re-ground them here:

**`validate-skills.sh` (Phase 5 / 10 / 21 — relayed verbatim):**
`DEAD-REF`, `MISSING-DESC`, `BAD-NAME`, `RESERVED-NAME`, `NAME-MISMATCH`,
`NAME-COLLISION`, `INVALID-JSON`, `DUPLICATE-KEY`, `DUPLICATE-ENTRY`,
`MISSING-PRE-APPROVED`, `MEMORY-OVERFLOW`, `UNREGISTERED-HOOK`, `SUSPICIOUS-TIMEOUT`,
`BAD-FRONTMATTER-SCHEMA`, `BAD-RULE-FRONTMATTER`, `RULE-OVERSIZED`,
`DESCRIPTION-TOO-LONG`, `DESCRIPTION-TRUNCATED`, `OVER-500-LINES`, `MISSING-TOC`,
`CHAINED-REF`, `NO-PROGRESSIVE-DISCLOSURE`, `THIRD-PERSON`,
`UNKNOWN-FRONTMATTER-FIELD`, `EMBEDDED-SECRET`, `UNFLAGGED-DESTRUCTIVE`,
`STALE-THRESHOLD`, `GUIDANCE-FETCH-FAILED`.

**`scan-graph.sh` (Phase 2 / 11 / 20 — read from `graph-scan.json`):**
`PLUGIN-BROKEN-REF`, `PLUGIN-MISSING-MANIFEST`, `PLUGIN-VERSION-DRIFT`,
`REF-CIRCULAR`, `REF-TOO-DEEP`, `REF-ORPHAN`, `MEMORY-DEAD-LINK`,
`MEMORY-ORPHAN-FILE`, `MEMORY-DUP-ENTRY`, `MEMORY-STALE-DATE`.

**`scan-history.sh` (Phase 7 / 9 / 15 / 16 / 19 / 22 / 23 — metric-derived):**
`SKILL-NEVER-FIRED`, `SKILL-DORMANT`, `SKILL-MISFIRING`, `SKILL-ORPHAN`,
`SKILL-TOOL-UNUSED`, `SKILL-TOOL-UNDECLARED`, `PERM-DEAD-ENTRY`, `PERM-OVERBROAD`,
`HOOK-FAILING`, `HOOK-NEVER-FIRED`, `HOOK-EVENT-MISMATCH`, `RECURRING-DENIAL`,
`RECURRING-CORRECTION`, `MISSING-SKILL-GAP`, `AGENT-NEVER-SPAWNED`, `LOW-CACHE-HIT`,
`CONTEXT-BLOAT`.

> History-derived tags are deterministic *in their metric* (the count came from
> `history-scan.json`) but the **threshold interpretation is the orchestrator's**.
> They still skip the gate — but the Evidence locator the report attaches must cite
> the metric (`0 invocations / 30d`, `284/304 failed`), so the number that
> justified the finding is visible. Do not re-mine the JSONL.

If a tag is NOT in the three lists above, it is a JUDGMENT tag — verify it.

## Evidence required per judgment tag

For each judgment finding, the evidence below MUST be obtainable. If it is not, the
finding is not grounded (→ downgrade or drop). "Obtainable" means you re-read or
re-grepped and saw it — not that it seems true.

| Tag | Phase | Concrete evidence required to KEEP |
|-----|-------|-------------------------------------|
| `WEAK-DESC` | 8 | Quote the actual `description` (+ `when_to_use`) and show the missing/generic "when to use" half. Quoting "what it does" only is not enough — the gap must be visible in the quoted text. |
| `UNDER-TRIGGER` | 8 | Name the concrete case the skill handles (cite the SKILL.md line) that the CLAUDE.md "Skills" table omits. Both sides quoted. |
| `OVER-TRIGGER` | 8 | Quote the CLAUDE.md trigger AND show the SKILL.md does NOT cover it (grep of the body returns nothing for that capability). |
| `NEEDS-REFERENCES` | 8 | Cite the SKILL.md line count (> `skillMd.maxLines × 0.6`) AND confirm `skills/<name>/references/` is absent/empty. Two facts, both checked. |
| `NO-EXAMPLES` | 8 | Grep the SKILL.md for an "Examples"/`User says:` section and show zero hits. |
| `NO-TROUBLESHOOTING` | 8 | Grep the SKILL.md for "Common Issues"/"Troubleshooting" and show zero hits. |
| `BURIED-CRITICAL` | 8 | Cite the line number (> 50) where the critical instruction sits AND quote it so "critical" is self-evident. |
| `ORPHAN-GUIDE` | 17 | Show the inbound grep across CLAUDE.md + settings.json + every SKILL.md/`references/` found ZERO references to the file basename, AND the file exists under `documentation/guides/`. Zero-inbound is the proof; assert it from the grep, not from "looks unused". |
| `ORPHAN-PATTERN` | 17 | Same as `ORPHAN-GUIDE`, scoped to `patterns/`. |
| `MISSING-TRIGGER` | 17 | Quote the entry present in CLAUDE.md "Automatic Triggers" but absent from settings.json `automatic-guide-triggers` (or vice-versa) — both files checked, the asymmetry shown. |
| `REPURPOSE` | 18 | Show all four Phase-18 gates hold: topic ∈ a named skill's domain; NOT already in that skill's SKILL.md/`references/` (grep shown); contains actionable patterns; ≥ 300 words (cite the count). Name the `<source> → <skill>/references/<name>.md` target. |
| `CLAUDEMD-STALE` | 12 | Quote the CLAUDE.md line (command/path/version) AND show the contradicting real artifact — the path that does not resolve, the script that is gone, the version in `package.json`/`pom.xml` that differs. Both quoted. |
| `CLAUDEMD-GENERIC` | 12 | Quote the boilerplate line AND assert it would read true for an unrelated repo. A repo-specific line that merely reads plainly is NOT this. |
| `CLAUDEMD-THIN` | 12 | Show the absence: grep for build/test/run commands AND an architecture/directory map both return nothing. A short-but-complete CLAUDE.md is not thin. |
| `DUPLICATE-LOGIC` | 14 | Quote the overlapping check from BOTH hook scripts (the same condition, two files). |
| `MISSING-ENFORCEMENT` | 14 | Name the critical rule (quote it) AND assert a *deterministic* check is feasible AND show no hook enforces it (grep of hook scripts). All three. |
| `DEAD-MATCHER` | 14 | Quote the matcher value AND confirm the event is a tool-event (`PreToolUse`/`PostToolUse`/`PostToolUseFailure`/`PermissionRequest`/`PermissionDenied`) AND the matcher is not a real tool name. Event-typed matchers (`SessionStart`, `PreCompact`, …) are NOT findings — disprove if so. |
| `MISSING-AGENT-TRIGGER` | 14 | Quote the agent `description` trigger AND show no CLAUDE.md path reaches it (grep). |
| `OVERLAPPING-AGENT` | 14 | Quote both agents' descriptions and show the shared problem space with no differentiating clause. |
| `BROAD-PATTERN` | 14 | Quote the actual `permissions.allow` entry (e.g. `Bash(cat:*)`) AND state the narrower scope it should carry. |
| `STALE-REMINDER` | 14 | Quote the `reminders` entry AND show the skill instruction it contradicts, OR show the file it names no longer resolves. |
| `SKILL-LOW-RELEVANCE` | 6 | Show the description-keyword grep against the project tree returned zero hits (advisory — tolerate FPs, but still cite the zero). |
| `SKILL-DUPLICATE-DOMAIN` | 6 | Cite the keyword-set Jaccard ≥ 0.6 between the two named skills. |
| `NEW-RULE` / `NEW-PATTERN` / `NEW-TRIGGER` / `NEW-REFERENCE` / `SKILL-UPDATE` | 4 | Additive Discovery items grounded in the **session transcript**, not the tree. Keep only if you can quote the session turn (the user correction, the repeated request, the applied external lookup). No transcript evidence → drop; never invent a Discovery item from the tree alone. |

`SKILL-BUDGET-OVERFLOW` straddles: the char total is script-derived
(`validate-skills.sh --listing-cost`) → fast-path the **number**; but if the finding
rests on "an active session showed the truncation banner", ground that half by
quoting the `+N more` banner from the transcript or drop that justification.

## Disproof checklist (run before keeping)

Adapted from the verifier's steps 3–7, retargeted from "diff/code" to "the
`.claude/` tree". For each judgment finding, try to disprove via:

1. **Established convention.** Is the flagged shape the norm across the tree (5+
   skills do the same)? Then it is a convention, not a defect → drop.
2. **Intentional exception.** Does a nearby comment / `<!-- … -->` marker /
   frontmatter field explain it (e.g. `<!-- DO NOT COMPRESS -->`, a deliberate
   name-only override)? → drop.
3. **Already covered elsewhere.** Is the concern already emitted by a deterministic
   tag (don't double-report a `DEAD-REF` as a judgment finding) or by another phase
   that owns it? → drop the duplicate.
4. **Accurate-and-short is not a finding.** A terse CLAUDE.md / description /
   SKILL.md where every line is correct and current is fine. Brevity ≠ defect.
   (`claude-md-quality.md`: "a short but accurate CLAUDE.md is not a finding.")
5. **Resolves on disk.** For any ORPHAN/DEAD/STALE claim, the artifact must actually
   be missing/unreferenced. If the reference resolves, the command exists, or the
   path is live → the finding is disproven → drop. (The single highest-value
   false-positive guard for this tool.)
6. **Reachable, not hypothetical.** "This trigger could be ambiguous", "this could
   overflow someday" with no concrete artifact on disk → not grounded → downgrade to
   OBSERVATION at most, never a tagged finding.
7. **Right scope.** `CLAUDE.local.md` personal-preference content is judged but never
   proposed for commit; project vs user tree attribution is correct.

## Outcome: keep / downgrade / drop

After the evidence check + disproof checklist, each judgment finding lands in exactly
one bucket:

- **Grounded** (evidence obtained, no disproof) → **KEEP** the finding with its tag,
  and attach an **Evidence:** locator (a quoted token / resolved-or-missing path /
  metric) per `report-format.md`. The locator is what you grounded it on — not a
  restatement of the problem.
- **Plausible but ungrounded** (evidence could not be quoted, yet the concern is
  real-sounding and non-misleading) → **DOWNGRADE** to a free-text `[OBSERVATION]`
  line. It loses its tag, its severity chip, and its slot in the `Proposed Changes`
  block — it becomes a non-actionable note the user may act on manually. Use this
  sparingly; prefer drop when in doubt that it adds value.
- **Disproven** (a disproof in the checklist fired, or the artifact resolves fine) →
  **DROP silently.** Do not narrate the drop in the report.

`[OBSERVATION]` is the existing free-text bucket ("not a tag … things the user should
know that aren't actionable") — downgrading reuses it, no new vocabulary.

## Self-check (before handing back to the Pre-print pass)

- For every KEPT judgment finding: "Did I actually re-read/re-grep the cited artifact,
  or am I trusting my Phase 6–19 first pass?" If you did not fetch it, fetch it now,
  then decide.
- A `[must-fix]` (Critical-tier) judgment finding kept without a quotable Evidence
  locator is a calibration smell — ground it harder or downgrade it. Top severity is
  earned by proof, never by inference from naming/type.
- Re-reads for independent findings have no inter-dependency — issue them in parallel
  (one turn, multiple `Read`/`Grep` calls).
