# Spec: Align claude-markdown-health-check (v0.18.0 -> 0.19.0) with the Agent Skills best-practices page

Repo: `~/work/claude-markdown-health-check`. All paths below are relative to it unless absolute.
Source page: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices

## Objective + success criteria

Add 5 deterministic tags to `plugin/commands/scripts/validate-skills.sh`:

| Tag | Tier / helper | Fires when |
|---|---|---|
| `DESC-XML-TAG` | Critical / `error` | skill `description` contains an XML-style tag |
| `WINDOWS-PATH` | Structural / `warning` | backslash file path (`scripts\helper.py`) in SKILL.md or a reference, outside fenced code |
| `TIME-SENSITIVE` | Hygiene / `warning` | "before/after/until/as of <Month> <YYYY>" outside fenced code, `<details>`, and Old-patterns/legacy/deprecated sections |
| `VAGUE-NAME` | Hygiene / `warning` | skill name is a bare generic word, or a reference file is `doc<N>.md` / `file<N>.md` |
| `RESERVED-WORD-PORTABILITY` | Hygiene / `warning` | skill name contains `anthropic` or `claude` (case-insensitive substring) |

Success:
- `bash tests/run.sh` exits 0, with 8 new eval cases (ids 120-127: 5 positive + 3 negative/exemption) green and every pre-existing case unchanged.
- `shellcheck -S warning plugin/commands/scripts/*.sh tests/*.sh` is clean (CI runs exactly this).
- Every new tag appears in all registries (step 6).
- Version reads 0.19.0 everywhere.
- Dogfood hit list (step 8) is reviewed.

Existing `RESERVED-NAME` (the `synced` directory) is untouched.

## Facts pinned from the code (do not rediscover)

- **Emit helpers** (`validate-skills.sh:147-148`): `error()` prints `[ERROR] <msg>` and sets `ERRORS++` and `EXIT_CODE=1`. `warning()` prints `[WARN]  <msg>` and sets `WARNINGS++`. The tag is just a `[TAG]` prefix inside the message. Test extraction (`tests/lib.sh:22-27`) greps `^\[(ERROR|WARN)\]\s+\[[A-Z0-9-]+\]`, so every new finding MUST start `[TAG] `.
- **Severity is not computed in the script.** The tier lives in the "Tag Set (canonical)" lists in `plugin/commands/claude-markdown-health-check.md:~455-463` (Critical / Structural / Hygiene), which drive the red/orange/yellow badge. The script only picks `error` vs `warning`. So:
  - `DESC-XML-TAG` goes in the Critical list and uses `error()`. This makes the validator exit 1; that is intended by the locked decision.
  - `WINDOWS-PATH` goes in the Structural list.
  - `TIME-SENSITIVE`, `VAGUE-NAME` and `RESERVED-WORD-PORTABILITY` go in the Hygiene list.
  - All use `warning()` except `DESC-XML-TAG`.
  - `report-format.md:43` is only the tag-to-domain map, not severity.
- **Callers of `validate_skill_md`** (`:1639`, `:1654`): the same function validates `skills/*/SKILL.md` (`is_skill_md=1`) AND `commands/*.md` (`is_skill_md=0`). All five new checks must be gated `is_skill_md=1` (the docs page is about skills; command descriptions legitimately carry `<arg>` placeholders). Consequence: the plugin's own command file `claude-markdown-health-check.md` does not trigger `RESERVED-WORD-PORTABILITY`.
- **Existing fenced-code helper:** `_body_stream()` (`:1125-1135`) strips frontmatter and fences but drops line numbers and does not know `<details>` or legacy sections. Do not change it (used by `OVER-CONSTRAINED`). Add a sibling helper (step 2). The fence toggle regex to reuse is `/^[[:space:]]*```/`.
- **Reference loops** (`:1689-1716` `skills/*/references/*.md`, `:1727-1752` `$CLAUDE_DIR/*/references/*.md`) have `ref_name`/`ref_file`. Each already ends with `check_embedded_secrets` + `check_unflagged_destructive`; add the new calls there.
- **Name resolution** (`:446-451`): `name="${name_field:-$dir_name}"` for SKILL.md. Reuse that `$name` variable for the VAGUE-NAME and RESERVED-WORD checks.
- **CI** (`.github/workflows/ci.yml`) runs `shellcheck -S warning plugin/commands/scripts/*.sh tests/*.sh`, `bash -n`, then `bash tests/run.sh`. shellcheck is installed locally (`/usr/bin/shellcheck`). Locally, `shellcheck` must be run explicitly before the final gate.
- **Anonymization gate** (`tests/check-anonymization.sh`): greps plugin/, evals/, tests/fixtures/, README.md against a blocklist. The committed example blocklist has invented patterns, and the real one is gitignored. Fixture/eval names are otherwise unconstrained. Use neutral names (`demo`, `alpha`) and no real employer/project/ticket strings.
- **validate-evals.sh constraints** (`plugin/commands/scripts/validate-evals.sh:44-112`):
  - `id` must equal the filename stem.
  - `.command` must be `claude-markdown-health-check`.
  - `fixture.kind` is `claude-tree`.
  - `fixture.dir` must exist and contain `dot-claude/`.
  - `scanners` must be a subset of `{validate-skills, scan-graph, scan-history}`.
  - `grader.method=code` needs `success_criteria` as an object with an array `must_detect`.
  - Nothing constrains name format beyond the stem rule.
- **Eval ids:** highest existing is 119. Use ids 120-127.

## Fixture impact analysis (existing tree)

Grepped all `tests/fixtures/**` for each new pattern:

- **DESC-XML-TAG:** no existing skill description has `<...>`. No impact.
- **WINDOWS-PATH:** only backslash text in fixtures is `rm\s+-rf` in `destructive-context/.../safety/SKILL.md:8`. It sits in inline backticks, but the regex requires `seg\seg.ext` with an extension. `rm\s+-rf` has no `.ext` after the second segment, so it does not match. No impact. (Inline backticks are deliberately NOT stripped: `` `scripts\helper.py` `` is exactly how the bad form is written.)
- **TIME-SENSITIVE:** no month-year phrase anywhere in fixtures. No impact.
- **VAGUE-NAME, skill name:** the only skill named `helper` is `weak-desc/dot-claude/skills/helper/SKILL.md`, but eval `13-weak-desc` is `llm-rubric` with `scanners: []`, so the code gate never runs it. The LLM run would additionally emit a Hygiene `VAGUE-NAME`; the rubric only requires WEAK-DESC/UNDER-TRIGGER and forbids invented must-fix findings (Hygiene is not must-fix). No edit needed. `agent-plugin-forbidden/.../agents/helper.md` is an agent and is not routed through `validate_skill_md`. `yaml-list-tools/.../listtools` is not an exact match.
- **VAGUE-NAME, reference filename:** `ref-cross-skill-mention/.../bravo/references/notes.md` exists. The draft regex `notes?` would have fired there, so the spec narrows the regex to `^(doc|file)[0-9]+\.md$` (digits required, matches the locked examples `doc2.md`/`file1.md`). `notes.md` and `misc.md` are out of scope. No fixture impact.
- **RESERVED-WORD-PORTABILITY:** no fixture skill is named with a `claude`/`anthropic` segment. The `claudemd-*` fixtures are fixture directory names, not skill names, and are never scanned as names. `reserved-name` (dir `synced`, name `synced`) does not match. No impact.
- **`clean` fixture:** contains no skill description tag, backslash path, date phrase or vague name. Stays silent for all five tags. It is the regression guard (`expect_clean`).
- Net: **zero existing fixtures newly fire; no `must_not_flag` edits to existing evals are required.** Each new eval adds the other new tags to its own `must_not_flag` for isolation.

## Files to create / change

Change:
- `plugin/commands/scripts/validate-skills.sh`: header comment, new constants, `_prose_lines` helper, `check_time_and_paths` helper, calls in `validate_skill_md` and both reference loops.
- `plugin/references/report-format.md:43`: add the 5 tags to the **Skills** domain list (`WINDOWS-PATH` and `TIME-SENSITIVE` in reference files are still Skills-domain; they are the skill's own references).
- `plugin/references/finding-verification.md:~54-70`: add the 5 tags to the deterministic fast-path list (`validate-skills.sh` block).
- `plugin/commands/claude-markdown-health-check.md`:
  - line ~188 Phase-5 trust sentence: add "XML tags in descriptions, Windows-style paths, time-sensitive wording, vague names, reserved words (portability)";
  - Tag Set lists ~455-463: `DESC-XML-TAG` in Critical, `WINDOWS-PATH` in Structural, the other three in Hygiene.
- `plugin/references/frontmatter-schema.md`:
  - rewrite line 21 (see step 3);
  - add 5 rows to the tag table near lines 15-18 (tag | trigger | tier), mirroring the `DESC-TOO-SHORT` row format.
- `README.md`: version badge line 4; "What it checks" Skills row (line 26) gains "XML tags / reserved words in names, Windows paths, time-sensitive wording, vague names"; acknowledgements bullet (line ~319, "`RESERVED-NAME` matched ... substrings") gets one added sentence that the portability concern now has its own Hygiene tag.
- `plugin/.claude-plugin/plugin.json`: `"version": "0.19.0"`.
- `.claude-plugin/marketplace.json`: `"version"` is **0.16.1 (already drifted from 0.18.0)**; bump to 0.19.0 in the same commit. Pre-existing drift, so fix it rather than leave it.

Create:
- `evals/120`-`127` (see step 7 table: 5 positive + 3 negative).
- Fixtures: `tests/fixtures/<slug>/dot-claude/skills/<skill>/SKILL.md` (+ `references/` where needed). Slugs: `desc-xml-tag`, `reserved-word-portability`, `vague-name`, `windows-path`, `time-sensitive`.

## Open questions / risks

1. **DESC-XML-TAG fires a hard error on placeholder-style text.** Dogfood: `~/.claude/skills/gitlab/SKILL.md` description contains `!<iid>` and will fire. Locked decision is "any XML tag counts" (the docs forbid it), so the default is to fire and report it as a true positive for the user to fix. If the user wants backticked placeholders exempt, that is a one-line regex change. Do not pre-empt.
2. **Plugin-dir dogfood is nearly empty.** `validate-skills.sh plugin/` only reaches `commands/*.md` (is_skill_md=0, so all five are gated off) and has no `skills/`. `plugin/references/` is not under `$CLAUDE_DIR/*/references`. So the plugin dir yields no new findings by construction. Mitigation: ad-hoc check of `plugin/references/*.md` with the same regexes (step 8), read-only.
3. **TIME-SENSITIVE scope.** Locked decision lists `before|after|until|as of <Month> <YYYY>`; review adjusted it to also accept `since`, an optional day (`August 5, 2025`) and day-first (`5 August 2025`). Bare `before <YYYY>` stays out.
4. **`extract_field` limitation (documented, not fixed):** it misses plain-scalar continuation lines that are not indented-block/`>`-folded, so a multi-line plain `description:` may only be checked on its first line for DESC-XML-TAG. `extract_field` is shared by every check and is deliberately NOT changed.
4b. **Indented (4-space) code blocks** are not treated as code by any exemption; out of scope, accepted false-positive risk for WINDOWS-PATH/TIME-SENSITIVE.
4c. **Escaped-markdown false positives for WINDOWS-PATH** (`snake\_case.py`): handled by requiring segment 2 to start with `[A-Za-z0-9]`. `\n`/`\t` escapes inside prose like `a\nb.txt` would match; accepted as rare, documented in the eval's expected_behavior.
5. **Reserved words = case-insensitive substring** (adjudicated; the page says "contain"). The old `RESERVED-NAME` substring bug was an *error* on a legal name; this is a Hygiene warning, so substring is acceptable. Note `claudette` would fire; state in frontmatter-schema.md.
6. `marketplace.json` version drift is pre-existing; bumping it is in scope only because the version bump touches the same manifest set.

## Steps

### 1. Constants + header (validate-skills.sh)
- Description: after `RESERVED_SKILL_DIR="synced"` (line 63) add:
  - `VAGUE_SKILL_NAME_RE='^(helpers?|utils?|tools?|documents?|data|files?)$'`
  - `VAGUE_REF_NAME_RE='^(doc|file)[0-9]+\.md$'`
  - `RESERVED_WORD_RE='anthropic|claude'` (used with `grep -Eiq`: case-insensitive SUBSTRING match anywhere in the name, fallback dir name; matches the docs wording "contain")
  - `DESC_XML_TAG_RE='</?[A-Za-z][A-Za-z0-9_:-]*/?>'` (bare tags only, no attribute clause, so `x<y and y>z` and `a < b > c` do not match; `<iid>`, `List<String>`, `<b>` do)
  - `WINDOWS_PATH_RE='[A-Za-z0-9_.-]+\\[A-Za-z0-9][A-Za-z0-9_.-]*\.[A-Za-z0-9]{1,5}\b'`
  - `TIME_MONTH='(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?'` and
    `TIME_SENSITIVE_RE='\b(before|after|until|as +of|since) +('"$TIME_MONTH"' +([0-9]{1,2},? +)?[0-9]{4}|[0-9]{1,2} +'"$TIME_MONTH"' +[0-9]{4})\b'` (grep `-Ei`; month names case-insensitive; optional day; day-first form). Single-space-tolerant (` +`) between all words.
- Update the header comment (line 3) to "verified <today 2026-10-06>" and mention the five new checks.
- Key decision: constants are defined once and used by both SKILL.md and reference paths.
- Default: ERE only (`grep -E`), no `-P`.
- Verify: `bash -n`; `shellcheck -S warning`.
- Files: `validate-skills.sh`.

### 2. `_prose_lines [mode]` helper (new, next to `_body_stream` ~line 1136)
- Description: awk that prints `NR:text` for prose lines only. Takes a mode: `full` (all exemptions, used by TIME-SENSITIVE) or `fence` (frontmatter + fenced code only, used by WINDOWS-PATH; no `<details>`/legacy exemption).
  - Skip frontmatter: `NR==1 && /^---[[:space:]]*$/` sets `fm`, cleared on the closing `---`.
  - Skip fences: toggle on `/^[[:space:]]*(```|~~~)/` (both fence styles), same toggle idea as `_body_stream`.
  - `full` mode only, skip `<details>`: a line containing both `<details` and `</details>` is skipped as a single line WITHOUT setting the flag; otherwise set on `<details`, clear (and skip that line) on `</details>`.
  - `full` mode only, skip legacy sections: a heading matching `tolower($0) ~ /^#+ +(old patterns?|legacy|deprecated)([^a-z]|$)/` (heading must START with the word) records its level (`match($0,/^#+/)` -> `RLENGTH`) and sets `legacy=1`. Any later heading with level <= recorded level clears it, and is itself re-tested.
- Key decision: new helper rather than changing `_body_stream`, whose output feeds the `OVER-CONSTRAINED` and `CLAUDEMD-OBVIOUS` metrics (no line numbers there).
- Default: awk `tolower` and `match` are POSIX awk, no gawk extensions.
- Verify: unit-check by piping a sample file with each construct through the function in a scratch shell (read-only, `/tmp`); expect only the prose lines.
- Files: `validate-skills.sh`.

### 3. RESERVED-WORD-PORTABILITY + VAGUE-NAME (skill name), in `validate_skill_md` after the RESERVED-NAME block (~line 470)
- Description (inside `if [ "$is_skill_md" = 1 ]`; `$name` already resolved at line 448):
  ```
  if printf '%s' "$name" | grep -Eiq "$RESERVED_WORD_RE"; then
      warning "[RESERVED-WORD-PORTABILITY] $skill_name: name '$name' contains a reserved word (anthropic/claude) — legal in Claude Code, but rejected when the skill is uploaded to the API or claude.ai"
  fi
  if printf '%s' "$name" | grep -Eq "$VAGUE_SKILL_NAME_RE"; then
      warning "[VAGUE-NAME] $skill_name: name '$name' is a generic word — prefer a specific, descriptive name (e.g. processing-pdfs)"
  fi
  ```
- Also update `frontmatter-schema.md:21`. Replace the "no word is forbidden inside a name" tail with: `RESERVED-NAME` is unchanged, and Claude Code itself accepts `claude-api`; but the Agent Skills API/claude.ai upload rejects names containing `anthropic` or `claude`, so a name containing `anthropic`/`claude` (case-insensitive substring) emits the Hygiene hint `RESERVED-WORD-PORTABILITY` (never an error).
- Also update the comment block at validate-skills.sh lines 460-463 ("nothing forbids `anthropic` or `claude`") to point to the new check.
- Key decision: the two are warnings, only for `is_skill_md=1`; reserved-word match is case-insensitive substring.
- Verify: fixtures in step 7 fire. `RESERVED-NAME` is not emitted for `claude-tools`. `BAD-NAME`/`NAME-MISMATCH` are not emitted.
- Files: `validate-skills.sh`, `frontmatter-schema.md`.

### 4. DESC-XML-TAG in `validate_skill_md` description block (~line 396, inside `if [ -n "$desc" ]`, after THIRD-PERSON)
- Description:
  ```
  if [ "$is_skill_md" = 1 ] && printf '%s' "$desc" | grep -Eq "$DESC_XML_TAG_RE"; then
      error "[DESC-XML-TAG] $skill_name: description contains an XML-style tag — the docs forbid XML tags in description (it is injected into the system prompt)"
  fi
  ```
- Key decision: `extract_field` already joins multi-line/block-scalar descriptions into one line, so a single-line regex is enough. Backticked `<x>` still fires (locked decision, risk 1).
- Verify: eval 120. `clean` stays silent.
- Files: `validate-skills.sh`.

### 5. `check_time_and_paths <file> <display>` (new, after `_prose_lines`)
- Description: one function, called for SKILL.md and references.
  ```
  check_time_and_paths() {
      local file="$1" display="$2" hit
      [ -f "$file" ] || return 0
      hit=$(_prose_lines "$file" fence | grep -E "$WINDOWS_PATH_RE" | head -1 || true)
      [ -n "$hit" ] && warning "[WINDOWS-PATH] $display: Windows-style backslash path at line ${hit%%:*} — use forward slashes (scripts/helper.py)"
      hit=$(_prose_lines "$file" full | grep -Ei "$TIME_SENSITIVE_RE" | head -1 || true)
      [ -n "$hit" ] && warning "[TIME-SENSITIVE] $display: date-conditioned wording at line ${hit%%:*} — it will rot; move legacy behaviour under an 'Old patterns' section"
      return 0
  }
  ```
  Under `set -e`, `[ -n .. ] && warning` as the last statement can return non-zero, hence the explicit `return 0`.
- Call sites:
  - `validate_skill_md`: next to `check_embedded_secrets` (line 509), guarded `[ "$is_skill_md" = 1 ] && check_time_and_paths "$skill_file" "$skill_name"`. Write it as `if` to stay `set -e` safe.
  - Skills reference loop only (`SKILLS_DIR/*/references`, after line 1712): `check_time_and_paths "$ref_file" "$ref_name"`.
  - NOT in loop 2 (`$CLAUDE_DIR/*/references`, command-support trees): all new checks are skill-only.
- Key decisions: one finding per file per tag (`head -1`) to keep output bounded; the line number is reported. Because `head -1` hides later lines and the harness has only whole-tree `must_not_flag`, exemptions are tested with dedicated negative fixtures (step 7), never by mixing exempt lines into a positive fixture.
- Default: `grep -Ei` for time, `grep -E` for the path.
- Verify: the positive and negative evals in step 7.
- Files: `validate-skills.sh`.

### 6. VAGUE-NAME (reference filenames) in both reference loops
- Description: in the skills reference loop (loop 1) only, after the `MISSING-TOC` block (~line 1699); NOT in loop 2:
  ```
  if printf '%s' "$(basename "$ref_file")" | grep -Eq "$VAGUE_REF_NAME_RE"; then
      warning "[VAGUE-NAME] $ref_name: reference filename is non-descriptive — name it for its content (form_validation_rules.md, not doc2.md)"
  fi
  ```
- Key decision: digits are required so `notes.md` (`ref-cross-skill-mention` fixture) does not fire.
- Verify: eval 122 (also contains a `bad-name`-free skill dir `helper`).
- Files: `validate-skills.sh`.

### 6b. Register tags everywhere
- `report-format.md:43` Skills list; `finding-verification.md` fast-path list; `claude-markdown-health-check.md` Phase-5 sentence (~188) and Tag Set tiers (~455-463); `frontmatter-schema.md` rows; README table.
- `frontmatter-schema.md` "Remediation order" list (line ~27): add one numbered line per new tag (DESC-XML-TAG: remove/replace the tag; WINDOWS-PATH: use forward slashes; TIME-SENSITIVE: move under an "Old patterns" section or drop the date; VAGUE-NAME: rename descriptively; RESERVED-WORD-PORTABILITY: rename only if the skill will be uploaded to the API/claude.ai).
- `README.md:238` case-count line is stale (says 104 cases: 92 code + 12 llm-rubric, numbered 01-105, but 117 files exist: 105 code + 12 llm-rubric). After adding 8 cases the real expected values are 125 files = 113 `code` + 12 `llm-rubric`; recompute with `ls evals/*.json | wc -l` and `grep -l '"method": "code"' evals/*.json | wc -l` at implementation time and write the computed numbers (and the new numbering range through 127), not these.
- Verify: tier placement by grepping the specific line, not a file-wide count: the line under `**Critical**` contains `DESC-XML-TAG`; under `**Structural**` contains `WINDOWS-PATH`; under `**Hygiene**` contains `TIME-SENSITIVE`, `VAGUE-NAME`, `RESERVED-WORD-PORTABILITY`; each tag also present once in `report-format.md` Skills line and the `finding-verification.md` fast-path list.
- Files: as listed above.

### 7. Evals + fixtures (code-graded, shape of `evals/88-claudemd-obvious.json`)
Each: `needs_home_override:false`, `scanners:["validate-skills"]`, `grader.method:"code"`, with `expected_behavior` lines. The harness only supports whole-tree `must_not_flag`, so **positive and negative cases are separate fixtures/evals**: a positive fixture holds one violation; a negative fixture holds only exempt/benign occurrences and sets `must_not_flag:[TAG]` (plus `expect_clean:true` where the tree has nothing else to fire). Positive `must_not_flag` lists the other new tags plus relevant neighbours.

| Eval | Fixture content | must_detect | must_not_flag |
|---|---|---|---|
| `120-xml-tag-in-description` | skill `demo`, `description: Processes <b>forms</b>. Use when ...` (40+ chars, third person) | `DESC-XML-TAG` path_substring `demo` | other 4 new tags, `DESC-TOO-SHORT`, `THIRD-PERSON` |
| `121-xml-tag-negative` | skill `alpha`, descriptions `Use when x<y and y>z holds` and `Compares a < b > c values` (two skills `alpha`, `beta`) | none | `DESC-XML-TAG` |
| `122-reserved-word-portability` | skill dir+name `claude-formatter` (and a second `my-Anthropic-demo` is NOT used: BAD-NAME) | `RESERVED-WORD-PORTABILITY` path_substring `claude-formatter` | `RESERVED-NAME`, `BAD-NAME`, `NAME-MISMATCH`, `VAGUE-NAME` |
| `123-vague-name` | skill `helper` + `references/doc2.md`; second skill `files` | `VAGUE-NAME` at `helper`, `VAGUE-NAME` at `doc2.md` (two entries) | `RESERVED-WORD-PORTABILITY`, `RESERVED-NAME` |
| `124-windows-path` | SKILL.md prose: `Run scripts\helper.py`; skill dir NOT `helper` | `WINDOWS-PATH` path_substring `SKILL.md` | `VAGUE-NAME` |
| `125-windows-path-exempt` | skill whose body has `scripts\helper.py` ONLY inside a ``` fence and inside a `~~~` fence | none | `WINDOWS-PATH` |
| `126-time-sensitive` | SKILL.md prose: `Use the old API before August 2025.`; one extra line `until 5 Mar 2026` (regex forms covered by the first hit; one finding reported) | `TIME-SENSITIVE` path_substring `SKILL.md` | `WINDOWS-PATH` |
| `127-time-sensitive-exempt` | skill whose body has the phrase ONLY: in a ``` fence; in a `~~~` fence; in a multi-line `<details>` block; in a single-line `<details>...</details>`; under `## Old patterns` (and a later same-level heading restores checking only for text without a date) | none | `TIME-SENSITIVE` |

Fixture text must be anonymous (`demo`, `alpha`, `beta`, `formatter`).
- `evals/01-clean-zero-findings.json` needs no edit (`expect_clean:true` already asserts an empty tag set).
- Spelling check: manually cross-check every `must_not_flag`/`must_detect` tag against the tags the script actually emits (a typo in `must_not_flag` passes vacuously).
- Files: `evals/12[0-7]-*.json`, `tests/fixtures/{desc-xml-tag,desc-xml-tag-negative,reserved-word-portability,vague-name,windows-path,windows-path-exempt,time-sensitive,time-sensitive-exempt}/dot-claude/skills/**`.

### 8. Dogfood (read-only; run after steps 1-6, before bump)
- `bash plugin/commands/scripts/validate-skills.sh ~/.claude` and `... ~/work/claude-markdown-health-check/plugin`.
- Pre-computed expectation (regex simulation against the live trees, read-only, already run):
  - `~/.claude` (16 skills): **one** new hit, `DESC-XML-TAG` on `skills/gitlab/SKILL.md` (`!<iid>`; true positive per locked rule, see risk 1). Zero hits for `WINDOWS-PATH`, `TIME-SENSITIVE`, `VAGUE-NAME`, `RESERVED-WORD-PORTABILITY` (no skill named helper/claude/etc., no `doc<N>.md`/`file<N>.md` references).
  - `plugin/`: no new findings by construction (risk 2). The repo's own skill/command name `claude-markdown-health-check` is a command (is_skill_md=0) so it does not fire `RESERVED-WORD-PORTABILITY`. The draft expected a hint here; that is wrong given the is_skill_md gate. If the user wants the plugin's own name flagged, that is out of scope since commands are not uploadable skills.
  - Ad hoc: run the same regexes over `plugin/references/*.md` through `_prose_lines`; triage any hit (e.g. date phrases in the doc text) as FP vs real. FPs get a regression fixture; true hits get fixed in the doc (in scope only if the doc is a skill reference).
- Verify: hit list recorded in the final message.

### 9. Version bump
- `plugin/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, README badge to 0.19.0.
- Verify: `grep -rn "0\.19\.0" plugin/.claude-plugin/plugin.json .claude-plugin/marketplace.json README.md` returns all 3 and no `0.18.0` / `0.16.1` remains in those files.

## Final verification gate

1. `shellcheck -S warning plugin/commands/scripts/*.sh tests/*.sh` (clean) and `for f in plugin/commands/scripts/*.sh tests/*.sh; do bash -n "$f"; done`.
2. `bash tests/run.sh` exits 0; report the case count (previous + 8) and that anonymization (ran against the committed EXAMPLE blocklist; the real one is local/gitignored), eval-schema, deterministic, history and docs-snippet sections all pass.
3. Run each new eval by its full id (prefix matching is `id` starts-with, so use full ids): `bash tests/run.sh 120-xml-tag-in-description`, `121-xml-tag-negative`, `122-reserved-word-portability`, `123-vague-name`, `124-windows-path`, `125-windows-path-exempt`, `126-time-sensitive`, `127-time-sensitive-exempt`; each green, then the full `bash tests/run.sh`.
4. Registry check: tier-line greps as in step 6b (not file-wide counts); README count line matches the computed numbers.
5. Dogfood output reviewed and the hit list stated.
6. Version grep (step 9).
7. Not run: `make evals` (LLM-graded, costs tokens) and no Maven/other builds. State this explicitly.

## Adversarial review

Findings -> verdict -> resolution (all folded into the steps above):
1. BLOCKER exemptions untestable (whole-tree must_not_flag, `head -1`) -> accepted -> separate negative fixture+eval per exemption-bearing tag (WINDOWS-PATH: ``` and ~~~; TIME-SENSITIVE: ```, ~~~, multi-line and single-line `<details>`, Old-patterns section); evals renumbered 120-127.
2. DESC-XML-TAG hits `x<y and y>z` -> accepted -> bare-tag regex `</?[A-Za-z][A-Za-z0-9_:-]*/?>`; negative eval 121 covers `x<y and y>z` and `a < b > c`; `<iid>`/`List<String>` stay flagged (locked).
3. `extract_field` misses plain-scalar continuation lines -> accepted as documented limitation -> not changed; risk 4.
4. WINDOWS-PATH must exempt fenced code only -> accepted -> `_prose_lines` `fence` mode.
5. Reference checks leaked into loop 2 -> accepted -> skills reference loop only; all new checks skill-only.
6. Reserved word segment vs substring -> accepted -> case-insensitive substring on name (fallback dir).
7. README:238 stale count -> accepted -> step 6b computes real counts.
8. Remediation order missing -> accepted -> step 6b adds lines.
9. Single-line `<details>...</details>` -> accepted -> awk skips without setting flag; fixture 127.
10. `~~~` fences -> accepted; indented code blocks out of scope (risk 4b).
11. Date regex gaps -> accepted -> ` +` spacing, optional day, day-first, `since`, case-insensitive months.
12. Legacy heading match too loose -> accepted -> anchored to heading start, same-or-higher level ends it.
13. Gate rigor -> accepted -> full eval ids, tier-line greps, tag-spelling cross-check (final gate).
14, 15. No action (llm-rubric evals untouched; anonymization gate runs against the example blocklist, stated in the gate).
