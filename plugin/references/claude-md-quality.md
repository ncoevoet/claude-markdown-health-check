# CLAUDE.md Content Quality

Loaded by `/claude-markdown-health-check` Phase 12. Phase 1 already checks CLAUDE.md *size* and `validate-skills.sh` checks its *dead links*, *imports*, and *local-file hygiene*; this rubric judges whether the file is actually *useful* to a fresh Claude session.

## Deterministic CLAUDE.md checks (validate-skills.sh, relayed here)

| Tag | Condition | Tier |
|---|---|---|
| `CLAUDEMD-DEAD-SCRIPT` | a `npm run <script>` mentioned in CLAUDE.md / CLAUDE.local.md / a `documentation/guides/*.md` it routes to, whose `<script>` is defined in no `package.json` from the file's directory up to the repo root. Lifecycle forms (`npm install`/`ci`/`test`) and placeholder tokens (`<app>:start`) never match; when no `package.json` exists on the path, grounding is skipped | Critical |
| `CLAUDEMD-DEAD-IMPORT` | an `@path` import in CLAUDE.md / CLAUDE.local.md does not resolve (relative to the importing file; `@~/…` resolves against `$HOME`) | Critical |
| `IMPORT-TOO-DEEP` | an `@import` chain exceeds the documented 4-hop maximum | Structural |
| `LOCAL-MD-TRACKED` | a `CLAUDE.local.md` sits inside a git working tree with no `.gitignore` entry covering it — personal overrides should be gitignored | Hygiene |
| `CLAUDEMD-OBVIOUS` | ≥6 consecutive bare path lines (a file-tree dump, list or fenced) of which ≥3 resolve on disk — the tree is one tool call away, so the lines buy nothing | Hygiene |
| `CLAUDEMD-MEMORY-DRIFT` | ≥3 memory-shaped bullets — "Remember …", "The user prefers …", or any bullet under a *Memories* / *Notes to self* / *Learned* heading — that auto-memory now owns | Hygiene |
| `OVER-CONSTRAINED` | the body carries ≥12 shouted absolutes (`NEVER`, `MUST`, `DO NOT`, `ALWAYS`) per 100 lines — also applied to every `@import`, which loads every turn | Hygiene |

Import detection only treats `@token` as an import when the token ends in an extension or starts with `./`, `../`, `~/`, or `/` — so `@mentions`, emails, and npm scopes are not flagged, and tokens inside fenced code blocks are ignored.


## What a good CLAUDE.md contains

A CLAUDE.md earns its context budget when it captures what a new session cannot infer from the code in a few minutes:

| Dimension | Good looks like |
|---|---|
| Commands & workflows | Real build / test / lint / run commands, copy-paste ready |
| Architecture map | Module *relationships*, entry points, data flow — what a directory listing does not say |
| Non-obvious patterns | Gotchas, quirks, workarounds, and the reasoning behind unusual choices — this is where most of the budget belongs |
| Conciseness | One concept per line; dense, no filler |
| Currency | Commands work today; file paths and tech versions are current |
| Actionability | Executable steps, not vague advice |

The weighting follows the Claude 5 context-engineering guidance: keep the file
lightweight, say briefly what the repo is for, and spend the tokens on the gotchas —
anything a session can read off the file system in one call has not earned a line.

## Red flags

- A build command that no longer works, a referenced script/file that was deleted or renamed, or a tech version that no longer matches the repo — `CLAUDEMD-STALE`. (The validator covers dead dot-claude links and, deterministically, dead `npm run <script>` mentions as `CLAUDEMD-DEAD-SCRIPT`; this judgment tag is for other commands, scripts, versions, and counts.)
- A **self-referential count or enumeration claim** the referenced file contradicts — "all N rules", "N modules", "N steps", "the M sub-files" — where the cited artifact actually holds a different number. Quote the "N" and the real count. Reuses `CLAUDEMD-STALE` (it is a claim the codebase contradicts).
- Generic boilerplate that would apply to any project — "write clean code", "follow best practices", framework descriptions copied from upstream docs — `CLAUDEMD-GENERIC`.
- A block that restates what the file system already shows — a `tree` dump, a bare directory list — `CLAUDEMD-OBVIOUS` (deterministic; relayed). An annotated map, where each entry states a relationship or a quirk, is the good version and is never this tag.
- No build/test/run commands, or no architecture map at all — too thin to help — `CLAUDEMD-THIN`.

## Verify before flagging

- Mentally execute (or run, read-only) each command against the real tree.
- Resolve every path the file names; flag the ones that miss.
- Compare version numbers / tool names against `package.json`, `pom.xml`, lockfiles.
- Judge "generic" by asking: would this sentence be true for an unrelated repo? If yes, it is filler.

## Do NOT flag

- A short CLAUDE.md is fine when every line is project-specific and current — brevity is not a defect.
- Style or wording nits — only flag content that is wrong, stale, generic, or absent.
- `CLAUDE.local.md` personal-preference content — judge it the same way, but never propose committing it.

## Per-file score (always-on for CLAUDE.md)

After the Pre-print grounding gate, summarize each in-scope CLAUDE.md as a 0–100 score with a
one-line criteria breakdown (`report-format.md` renders it). The score is a *presentation
summary computed from the surviving findings* — never its own finding, never gated. Start each
criterion at full weight and deduct:

| Criterion | Weight | Deduct when (from surviving findings / observations) |
|---|---|---|
| Commands & workflows | 15 | −15 if `CLAUDEMD-THIN` (no build/test/run); −6 per dead command (`CLAUDEMD-DEAD-SCRIPT`, or a `CLAUDEMD-STALE` about a command) |
| Architecture map | 15 | −15 if no module map; −6 per stale path; −8 if `CLAUDEMD-OBVIOUS` (a listing stands in for the map) |
| Non-obvious patterns | 30 | −30 if the file is only commands with no gotchas/quirks; −10 if `CLAUDEMD-MEMORY-DRIFT` (session facts crowding out durable ones) |
| Conciseness | 15 | −15 if over `claudeMd.maxLines`; −6 if `BODY-FILLER-HIGH`; −6 if `OVER-CONSTRAINED` |
| Currency | 15 | −5 per surviving `CLAUDEMD-STALE` / `CLAUDEMD-DEAD-SCRIPT` / `CLAUDEMD-DEAD-IMPORT` / `DEAD-REF` in this file |
| Actionability | 10 | −10 if `CLAUDEMD-GENERIC` dominates; −5 if commands are vague/non-runnable |

Floor each criterion at 0; sum for the file score. Grade band (matches the report scorecard):
**A ≥ 90 · B 70–89 · C 50–69 · D 30–49 · F < 30**. A clean, current, project-specific CLAUDE.md
scores in the 90s — the score should track the findings, so a file with zero findings never
scores below A.
