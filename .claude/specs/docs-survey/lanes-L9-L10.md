# Spec section: lanes L9 (rename) and L10 (docs + 0.20.0)

Repo `~/work/claude-markdown-health-check`, branch `feat/agent-skills-best-practices`. All paths relative to it. L9 and L10 run sequentially AFTER L1-L8 are merged; L9 first, then L10 (so L10 edits the already-renamed command file).

## L9 - rename plugin and command to `markdown-health-check`

### Inventory (measured with `git grep -n claude-markdown-health-check`)

Rename ("RN"):
- `plugin/.claude-plugin/plugin.json:2` `"name"`. Lines 9-10 (homepage, repository) = KEEP.
- `.claude-plugin/marketplace.json:9` plugin entry `"name"`. Lines 17-18 (homepage, repository) = KEEP. The top-level marketplace `"name": "ncoevoet-health-check"` is untouched.
- `plugin/commands/claude-markdown-health-check.md` -> `git mv` to `plugin/commands/markdown-health-check.md`. Inside: line 19 (fallback path `~/.claude/claude-markdown-health-check/references/<name>` -> `~/.claude/markdown-health-check/references/<name>`), line 57 (cache file `claude-markdown-health-check-guidance.json` -> `markdown-health-check-guidance.json`), line 139 (`/claude-markdown-health-check` invocation text). Also check the frontmatter `name:` if present (none matched by grep, so the command name comes from the filename).
- `Makefile:1,5,8,9,11,25,47,49,53` (header, CMD_SRC, CMD_DEST, REF_DEST, echo texts, uninstall `rm -rf "$(CLAUDE_DIR)/claude-markdown-health-check"`). Variable names unchanged.
- `README.md:1,18,81,120,136-142,232,257` (title, image alt, "available right away", usage, behavioural-eval text, tree), `:77` marketplace add = KEEP, `:78,83,85` plugin ids -> `markdown-health-check@ncoevoet-health-check` (marketplace add at 77/85 and clone URL at 94-95 = KEEP: `git clone .../claude-markdown-health-check.git` and `cd claude-markdown-health-check` keep the repo name), `:101` `commands/markdown-health-check.md`, `:102` `~/.claude/markdown-health-check/references/`. `:3` CI badge URL = KEEP.
- `plugin/commands/scripts/run-evals.sh:7,30` (prompt text), `run-evals-headless.sh:3,9,41,86,127,137,138,140` (`CMD_MD=...`, tmp `.claude/claude-markdown-health-check/references`, cache copy name), `validate-evals.sh:2,11,60,61` (the `.command` equality check and its error text).
- `plugin/commands/scripts/validate-skills.sh:226` comment example name.
- `plugin/references/{body-compression,claude-md-quality,context-coherence,finding-verification,post-report-menu,skill-listing-budget}.md` first lines (`/claude-markdown-health-check Phase N`).
- `evals/*.json` (all, `"command"` field, line 3; plus `"query"` line 4 or 11 in ~20 llm-rubric cases such as 13, 14, 15, 36-41, 77, 84, 91-rule-conflict) and `evals/README.md:1,22,37`.

Keep: every `github.com/ncoevoet/claude-markdown-health-check` URL, the clone dir, `marketplace add ncoevoet/claude-markdown-health-check`, marketplace name `ncoevoet-health-check`.
Historical (keep untouched): `.claude/specs/agent-skills-best-practices-alignment.md`, `.claude/specs/context-engineering-claude-5-alignment.md`, any `.claude/.scratch`.
No occurrences in `tests/**` or `tests/fixtures/**` (verified: no match in tests/*.sh; fixtures none). The harness keys only on script paths (`plugin/commands/scripts/*.sh`), NOT on the command name; only `validate-evals.sh` enforces the `command` value. There is no `plugin/commands/claude-markdown-health-check/` directory: references live at `plugin/references/`, resolved as `${CLAUDE_PLUGIN_ROOT}/references/<name>` (unchanged by the rename). Scripts resolve as `${CLAUDE_PLUGIN_ROOT}/commands/scripts/...` (unchanged).

### Steps
1. `git mv plugin/commands/claude-markdown-health-check.md plugin/commands/markdown-health-check.md`.
2. Bulk rename with an exclusion of KEEP/historical patterns: first protect the URLs, e.g.
   `git ls-files | grep -v '^\.claude/specs/' | xargs sed -i -E 's#(github\.com/ncoevoet|marketplace add ncoevoet|clone https://github\.com/ncoevoet)/claude-markdown-health-check#\1/@@REPO@@#g; s#claude-markdown-health-check#markdown-health-check#g; s#@@REPO@@#claude-markdown-health-check#g'`
   Then hand-fix README `cd claude-markdown-health-check` (KEEP) and the `ci.yml` badge. Do not run on `docs/demo.png` (binary: filter with `git ls-files '*.md' '*.json' '*.sh' Makefile`).
3. Collision check: `markdown-health-check.json` (config file) and `markdown-health-check-guidance.json` (cache) now share the stem with the command; harmless, different dirs/extensions. Orphaned old cache `~/.claude/.cache/claude-markdown-health-check-guidance.json` is simply refetched.
4. Update `run-evals-headless.sh` path at line 41 to `$PLUGIN/commands/markdown-health-check.md`.
5. README migration note (one line, under Install/Update): "Upgrading from <= 0.19.0: the plugin was renamed, so `claude-markdown-health-check@ncoevoet-health-check` no longer resolves; run `/plugin uninstall claude-markdown-health-check@ncoevoet-health-check` then `/plugin install markdown-health-check@ncoevoet-health-check`, and invoke `/markdown-health-check`." No shim, no alias command.
   `make install` users: README note `make uninstall` on the old checkout first (old `~/.claude/commands/claude-markdown-health-check.md` and `~/.claude/claude-markdown-health-check/` are not removed by the new Makefile); no new fallback logic.
6. Skill-listing key: the plugin command is listed in sessions as `<plugin>:<command>` = `claude-markdown-health-check:claude-markdown-health-check` today; after the rename it is `markdown-health-check:markdown-health-check` (slash form `/markdown-health-check`, or `/markdown-health-check:markdown-health-check` when disambiguating). Update any literal of the old key in docs/evals (grep: none found beyond the above).

### Gates (L9)
- `git grep -n claude-markdown-health-check -- . ':!.claude/specs'` must show ONLY lines containing `ncoevoet/claude-markdown-health-check`, `claude-markdown-health-check.git`, or `cd claude-markdown-health-check`, plus the README migration note. Exact check:
  `git grep -n claude-markdown-health-check -- . ':!.claude/specs' | grep -v -E 'ncoevoet/claude-markdown-health-check|claude-markdown-health-check\.git|^README.md:[0-9]+:cd claude-markdown-health-check|migrat|Upgrading'` -> empty.
- `bash plugin/commands/scripts/validate-evals.sh` (enforces `.command == "markdown-health-check"` after the edit), `bash tests/run.sh` exit 0, `shellcheck -S warning plugin/commands/scripts/*.sh`, `make -n install uninstall` shows only new paths.
- Local CLI HAS `claude plugin validate [--json] [--strict] <path>` (confirmed via `claude plugin --help`; it also has `claude plugin eval`, `details`). Gate commands:
  `claude plugin validate plugin/ --strict` and `claude plugin validate . --strict` (marketplace manifest at repo root). Expect no `claude-` reserved-prefix error on the name. Read-only; exit non-zero fails the lane.
- Dogfood: `bash plugin/commands/scripts/validate-skills.sh plugin` and `scan-graph.sh` on the repo's own plugin report no new finding from the rename (L7's reserved-name check must now pass on our own name).

## L10 - docs registration and version 0.20.0

### How L10 gets the tag list
Lanes L1-L8 must NOT edit docs. After merge L10 derives the truth from the merged scripts, not from lane reports:
```
emitted=$(grep -ohE '\[[A-Z][A-Z0-9-]+\]' plugin/commands/scripts/{validate-skills,scan-graph,scan-history}.sh | tr -d '[]' | sort -u)
documented=$(sed -n '/^## Tag Set/,/^## Output Rules/p' plugin/commands/markdown-health-check.md | grep -oE '`[A-Z][A-Z0-9-]+`' | tr -d '`' | sort -u)
comm -23 <(echo "$emitted") <(echo "$documented")   # new tags needing registration
```
(Pattern per the task: `grep -o '\[[A-Z-]*\]'`; widened with digits for safety. Filter false matches such as shell `[[ ... ]]` and `[OBSERVATION]` with an exclusion list `OBSERVATION|DEBUG|...` determined once by inspecting the diff.) Each new tag gets tier + domain + fast-path classification per its lane's severity (lane outputs record tag, tier, script, domain in a short table the orchestrator passes to L10; L10 cross-checks against the diff).

### Exact edit locations (line numbers at tip 88e99d5 and after the L9 rename; re-grep because L1-L8 do not touch these files, so numbers hold)
Format everywhere: backticked tags, comma-space separated, one paragraph per tier.
1. `plugin/commands/markdown-health-check.md`:
   - Tag Set section starts line 454. Lists: Critical line 457, Structural 460, Hygiene 463 (each a single long line of `` `TAG`, `TAG`, ``), Discovery 466. Append new tags at the end of the tier's line, before the trailing period/newline, keeping `, ` separators.
   - Phase 5 trust sentence: line 188 ("This is the deterministic layer. Trust its output for: ..."); add the new deterministic checks as short clauses in the same comma list. Also Phase 5 relay notes at lines 234, 251, 253 only if a lane added a new relay class.
2. `plugin/references/report-format.md`: "Tag -> domain map" lines 43-55, one bullet per domain `- **Domain** - \`TAG\` \`TAG\`` (space-separated backticks, NO commas). Add each new tag to its domain bullet (Hooks, Settings & Permissions, Plugins, Output Styles at line 50, Agents, Skills). Check the "Audit-meta" note at line 56 unaffected.
3. `plugin/references/finding-verification.md`: fast-path list lines ~52-90 grouped per script: `validate-skills.sh` block (starts ~line 55, ends `OUTPUTSTYLE-MISSING`.), `scan-graph.sh` block (`PLUGIN-BROKEN-REF`... ~line 78), `scan-history.sh` block (~line 85). Format: backticked tags, comma+space, wrapped at ~80 cols, group-closing period. Add new tags of deterministic scripts to the block of the script that emits them; judgment/LLM tags go in the verification table (line ~117) instead.
4. `README.md`:
   - "What it checks" table lines 24-44, row format `| **Area** | examples ... |`. Extend existing rows (Hooks 31, Hook reliability 32, Settings 35, Permission hygiene 36, Plugins & MCP 39, Plugin structure 40, Output styles 41, Agent frontmatter 34) and add rows only for genuinely new areas (e.g. "Plugin evals" for L8).
   - Phase table row 175 ("2 - Plugin + MCP Integrity") if L5/L7 changed scope.
   - Case-count line 238: `Cases live in evals/*.json (126 cases: 114 grader.method: code + 12 llm-rubric; numbered 01-128 with 43, 50 & 113 unused and 91 used twice)`. Recompute: `ls evals/*.json | wc -l`, `jq -r .grader.method evals/*.json | sort | uniq -c`; lanes add ids 130-194 so the range becomes `01-19x` with the unused ids listed from the actual gaps. Line 228 (`241 scanner + 13 history assertions`) updates from the `bash tests/run.sh` summary counts.
   - Tree line ~257 already renamed by L9.
   - Version badge line 4: `version-0.19.0-blue` -> `version-0.20.0-blue`.
5. Versions: `plugin/.claude-plugin/plugin.json:4` and `.claude-plugin/marketplace.json:12` -> `"0.20.0"`.

### Verify commands
Reusable one-liner, fails if any emitted tag is missing from the command's tier lists, report-format map, or finding-verification fast-path list (exit 1 and prints the offenders):
```
cd ~/work/claude-markdown-health-check; E=$(grep -ohE '\[[A-Z][A-Z0-9-]+\]' plugin/commands/scripts/*.sh | tr -d '[]' | sort -u | grep -vxE 'OBSERVATION|OK|CI'); rc=0; for f in plugin/commands/markdown-health-check.md plugin/references/report-format.md plugin/references/finding-verification.md; do m=$(for t in $E; do grep -q "\`$t\`" $f || echo $t; done); [ -n "$m" ] && { echo "MISSING in $f: $m"; rc=1; }; done; exit $rc
```
(The exclusion list is the set of non-tag bracket words found once by `comm`-diffing on the baseline tip; `finding-verification.md` legitimately omits judgment-only tags, so for that file restrict `E` to tags from lines emitting via `emit`/relay in deterministic scripts, or keep an explicit allowlist file `tests/judgment-tags.txt` subtracted first.) Add the check to `tests/run.sh` so CI enforces it.
Plus: `jq -r .version plugin/.claude-plugin/plugin.json .claude-plugin/marketplace.json` both `0.20.0`, `grep -c 'version-0.20.0' README.md` = 1, `bash tests/run.sh` exit 0, `claude plugin validate plugin/ --strict`.
