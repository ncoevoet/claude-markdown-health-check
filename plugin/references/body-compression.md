# Phase 13 — Body Compression (opt-in)

Optional pass that proposes caveman:lite rewrites of skill bodies, rule bodies, and reference files when filler density justifies it. Off by default. Invoked only when the user passes `--compress-bodies` to the command.

## Contents

- Why this is opt-in
- Detection sub-mode (always on, cheap)
- `--compress-bodies` mode — precondition checks, candidate selection, per-file rewrite, batch commit
- Guardrails
- When NOT to use this phase
- Why detection-only is a valid stopping point

## Why this is opt-in

- Listing-budget overflow (the audit's main complaint) is unaffected by body length — only the YAML `description` + `when_to_use` count there. Compressing bodies fixes a different problem (per-invocation token cost), and only when the skill is actually loaded.
- Compression is lossy. Lite intensity is the safest level but still rewords prose; on heavily curated skill bodies the diff needs review per-file, not blanket approval.
- The cavecrew/caveman plugin is a hard dependency for the rewrite path. The audit must not require it for the default scan.

## Detection sub-mode (always on, cheap)

Even without `--compress-bodies`, the default audit emits a `BODY-FILLER-HIGH` Hygiene finding when a SKILL.md / rule / reference file has:

- Body length ≥ 150 lines (under that, gains are smaller than diff noise)
- Filler-word density > 6% of body words, computed by:

  ```bash
  body_words=$(awk 'in_fm{if(/^---$/){in_fm=0}else{next}}
                    /^---$/ && NR==1{in_fm=1;next}
                    in_code{if(/^```/){in_code=0}else{next}}
                    /^```/{in_code=1;next}
                    {n+=NF} END{print n+0}' "$file")
  filler_hits=$(grep -ohE -w \
      '(just|really|basically|actually|simply|literally|essentially|you should|might want|in order to|in fact|of course)' \
      "$file" | wc -l)
  ratio=$(( filler_hits * 100 / (body_words + 1) ))
  ```

- AND the file does NOT already carry the `<!-- caveman:lite v1 -->` marker (idempotency guard).

The finding line follows the canonical format:

```
[BODY-FILLER-HIGH] [scope] path — N% filler over M body words; run --compress-bodies to fix
```

It points at the opt-in mode but never auto-runs.

## --compress-bodies mode (opt-in only)

Phase 13 runs only when the user invokes `/claude-markdown-health-check --compress-bodies` (alone or combined with depth flags). Sequence:

### Step 1 — Precondition checks

```bash
# 1a. caveman plugin available?
if [[ -d "$HOME/.claude/plugins/cache/caveman" ]]; then
    CAVEMAN_AVAILABLE=1
else
    CAVEMAN_AVAILABLE=0
fi

# 1b. cavecrew:cavecrew-builder reachable? (skill listing exposes it)
# The model checks the live skill listing for the line `cavecrew-builder` or `caveman:cavecrew`.
```

If `CAVEMAN_AVAILABLE=0`, offer one-time install via `AskUserQuestion` (single-select):

- **Install caveman plugin** — runs `claude plugin install caveman@JuliusBrussee/caveman` (or equivalent marketplace add)
- **Skip compression** — print "Phase 13 skipped: caveman plugin not installed" and continue

Never silently install. Never re-prompt within the same session if the user declined.

### Step 2 — Candidate selection (deterministic)

For each `*.md` under the audit scopes, include only files that meet ALL of:

1. Path matches one of: `skills/*/SKILL.md`, `rules/*.md`, `skills/*/references/*.md`, `documentation/guides/*.md`, `patterns/*.md`.
2. Body line count > 100 (after stripping YAML frontmatter and fenced code blocks).
3. Body is NOT ≥ 70% fenced code (compression gains <3% on code-heavy files).
4. File does NOT contain the literal marker `<!-- caveman:lite v1 -->` anywhere.
5. File does NOT contain the escape hatch marker `<!-- DO NOT COMPRESS -->`.
6. Filler density > 6% (per the detection formula above).

Sort the surviving list by `(filler_hits × body_lines)` descending — the files with the most filler and the most body get processed first.

Cap the selection at 10 files per invocation. Larger batches drown the diff review.

### Step 3 — Per-file rewrite flow

For each selected file, in order:

1. **Snapshot the diff baseline.** Record line count, body word count, filler hits.
2. **Spawn `caveman:cavecrew-builder`** with a constrained prompt:

   ```
   Apply caveman:lite compression to <file>.

   Rules:
   - Drop filler ("just", "really", "basically", "actually", "simply") and hedging
   - Keep articles (a/an/the) and full grammatical sentences
   - Keep section headings unchanged
   - Code blocks unchanged
   - Technical terms exact
   - Error strings quoted exact

   Do NOT modify:
   - YAML frontmatter
   - Code block content
   - Section heading text
   - Bullet structure
   - DO NOT add new sections (Examples, Common Issues, etc.) — compression only
   - DO NOT remove existing sections

   Goal: trim ~10-20% off body length while keeping every technical point.
   Return caveman diff receipt.
   ```

3. **Validate the result.** Reject the rewrite (and skip the file) if any of:
   - Section count (count of `^## ` lines) changed.
   - Bullet count (count of `^- ` and `^* ` lines) changed.
   - Code block count (count of ` ``` ` fences) changed.
   - YAML frontmatter changed.
   - Body delta < 8% (not worth the diff noise).
   - Body delta > 25% (too aggressive — content likely lost).

   On reject, restore the file from git (`git checkout -- <file>`) and tag the finding `[BODY-COMPRESSION-REJECTED] <file> — <reason>`.

4. **Append the idempotency marker.** On a successful rewrite, append a single line at the end of the file:

   ```
   <!-- caveman:lite v1 -->
   ```

   Subsequent runs skip the file by step 2's filter 4.

5. **Report.** Print one line:

   ```
   [BODY-COMPRESSED] <file> — body -<N>% (<old_lines> → <new_lines> lines)
   ```

### Step 4 — Batch commit prompt

After all candidates are processed, present a single `AskUserQuestion` (multiSelect) listing the successful rewrites:

- **Commit all rewrites** — single commit on a new branch `chore/caveman-lite-bodies-<date>`
- **Review each diff, then commit** — open each diff in turn for accept/skip
- **Stage only, no commit** — leave edits in working tree
- **Discard all rewrites** — `git checkout -- <files>`

The commit message template is:

```
chore(claude): caveman:lite compress N skill bodies

Trim filler and hedging from <list of files>. Frontmatter, code blocks,
section headings, and bullet structure preserved. Idempotency markers
added to prevent re-compression.
```

## Guardrails

- Phase 13 NEVER runs without `--compress-bodies`. The detection finding (`BODY-FILLER-HIGH`) does not imply consent — it documents the opportunity, no more.
- Phase 13 NEVER runs on uncommitted working trees. If `git status --porcelain` shows any modification to the candidate paths, abort with: `Phase 13: working tree dirty for <path> — commit or stash before running.`
- The cavecrew agent is given the file path; the orchestrator never includes file contents in its own prompts so the main thread context stays cold.
- All rewrites land on a feature branch (`chore/caveman-lite-bodies-<date>`). The orchestrator never pushes.

## When NOT to use this phase

- Files under 100 body lines — savings smaller than diff overhead.
- Files with active spec/test linkage (frontmatter has `examples_test:`) — rewording breaks test expectations.
- Skills under heavy iteration (file edited in the last 7 days per `git log -1 --format=%cr`) — wait until the author is done.
- First audit on a repo — fix structural and critical findings before touching prose style.

## Why detection-only is a valid stopping point

A repo that emits 12 `BODY-FILLER-HIGH` findings but never opts into `--compress-bodies` is still better off than one that received zero feedback. The finding tells the user where prose drift accumulates; the opt-in mode is the cheap path to act on it.
