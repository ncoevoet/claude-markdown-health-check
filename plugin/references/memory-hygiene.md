# Auto-memory Hygiene — Phase 20

Audits the link-index format of every `~/.claude/projects/*/memory/MEMORY.md`. Runs at Standard + Deep depth. Freeform MEMORY.md files (no `- [Title](file.md)` link entries) are left alone.

## Source

`scan-graph.sh` writes `graph-scan.json`. Filter on `.phase == 20`.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `MEMORY-DEAD-LINK` | linked `file.md` missing in the same memory directory | Critical |
| `MEMORY-ORPHAN-FILE` | `.md` in memory dir (other than `MEMORY.md`) with no matching `- [.](file.md)` line | Hygiene |
| `MEMORY-DUP-ENTRY` | same `file.md` linked from two different lines in `MEMORY.md` | Hygiene |
| `MEMORY-STALE-DATE` | a date string `YYYY-MM-DD` inside MEMORY.md is older than `MEMORY_STALE_DAYS` (env, default 365) | Hygiene |
| `MEMORY-STALE-CONTENT` | a memory file's body asserts a claim the current tree contradicts — **deterministic** when the body cites a missing `.claude/…` path (`validate-skills.sh`), **judgment** when it asserts a behaviour the code disproves (see below) | Structural |

## Report block

```
### Auto-memory
Indexes: N · Dead links: X · Orphans: Y · Dups: Z · Stale dates: W
```
Emit nothing when all four are 0.

## Content grounding — `MEMORY-STALE-CONTENT`

A memory is a point-in-time observation; over weeks the code drifts and the note silently lies. The
`reference` and `project` memory types are the usual offenders (they cite code); `feedback`/`user`
preference memories rarely have anything groundable. Two slices:

**Deterministic slice (`validate-skills.sh`, fast-path).** A memory body that cites a `.claude/…`
path (script/guide/config) which no longer resolves in the scanned tree is flagged automatically —
the same dead-`.claude/`-ref resolution the validator already does for CLAUDE.md. Reliable, CI-safe.
Runtime/state paths (`.claude/projects`, `.cache`, …) are skipped.

**Judgment slice (orchestrator Phase 20, Standard + Deep).** Everything the validator can't resolve
mechanically — chiefly a memory asserting a **behaviour** the code contradicts. Grounding requires
reading the file the memory describes, so it works only when that file is on disk (typically: you ran
the audit inside the project the memory is about). When the described project is NOT present, the
claim cannot be grounded either way — abstain (downgrade to `[OBSERVATION]`), never flag. That
no-false-positive discipline is the point.

**Extract only verifiable claims** — anything naming a concrete artifact:
- a file or directory path (`.husky/pre-commit`, `src/ivrs/ivr.model.ts`)
- a script or command (`npm run zod:install`, `bash x.sh`)
- a `file:line` / symbol citation
- a quoted behaviour about a named file ("pre-commit runs vitest+prettier")

**Ground each** against the current tree: resolve the path, look up the script, read the named file.
Keep the finding only when you can **quote the contradicting artifact** — the missing path, the
absent script, or the real file content that disproves the quoted behaviour. (Worked example: a
memory says "apps/ng pre-commit runs vitest+prettier"; `.husky/pre-commit` → `lint-staged` →
prettier only, vitest moved to pre-push ⇒ `MEMORY-STALE-CONTENT`, Evidence = the pre-commit hook.)

**Skip** (no finding):
- pure prose / preferences with nothing to resolve ("always reply in English").
- a claim the tree still satisfies — resolves on disk / script exists / file matches.
- when the memory already carries its own staleness disclaimer pointing at the same fact.

This is a JUDGMENT tag: it goes through the Pre-print grounding gate (`finding-verification.md`) and
is dropped unless the contradicting artifact is quotable. Propose the fix as *update the memory file
+ its MEMORY.md index line* — never silently delete a memory whose core lesson still holds.

## Remediation order

1. `MEMORY-DEAD-LINK` (Critical) → either restore the file or remove the link.
2. `MEMORY-DUP-ENTRY` → keep one line, delete the duplicate.
3. `MEMORY-ORPHAN-FILE` → add a `- [Title](file.md) — hook` line to MEMORY.md or delete the file.
4. `MEMORY-STALE-CONTENT` → update the memory body + its MEMORY.md index line to match the code; keep the lesson, fix the stale fact.
5. `MEMORY-STALE-DATE` → review whether the entry is still relevant; rewrite or delete.
