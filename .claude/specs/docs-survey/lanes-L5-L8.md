# Implementation spec: lanes L5-L8 (scan-graph.sh)

Repo `~/work/claude-markdown-health-check`, tip 88e99d5. All four lanes edit only
`plugin/commands/scripts/scan-graph.sh`, plus per-lane fixtures, evals and one reference doc.
Docs re-fetched 2026-10-06 with `curl -s https://code.claude.com/docs/en/<page>.md`; every quote below was
re-read in that fetch.

**Everything below was prototyped and run.** A copy of the repo in /tmp (scanner patched with all four lanes,
all fixtures and evals added) gave `bash tests/run.sh` -> `deterministic: 596 passed, 0 failed`, `ALL TESTS PASSED`
(anonymization gate, `validate-evals.sh` "155 case(s) valid", history and docs-snippets suites included),
`shellcheck -S warning` clean on the patched script. Baseline before the patch: green with 126 eval cases (127 files incl. README); after: 155 cases (29 new).
The code blocks in this plan are the prototype verbatim; the fixture generator is in the Appendix.

## 0. How scan-graph.sh emits findings (read first)

- `emit_finding <phase> <TAG> <path> <message>` (line 63) appends one JSON line
  `{phase, tag, scope, path, message}` to a temp file; at the end `jq -s` wraps them as
  `{"meta":{...},"findings":[...]}` (cache `$CLAUDE_PLUGIN_DATA/graph-scan.json`, bypassed by `--no-cache`).
- The `phase` number is the audit domain id. Existing usage: **2** = plugin/marketplace/MCP integrity
  (`scan_plugins`, `scan_plugin_self`, `scan_mcp`), **11** = ref graph, **20** = memory, **26** = output styles.
  New tags reuse these: L5, L7, L8 emit **phase 2**, L6 emits **phase 26**. No new phase number is needed.
- Tier (Critical/Structural/Hygiene/Discovery) is NOT stored in the JSON; it lives in the command file's tier lists and
  `references/*.md` tables (lane L10 registers the tags in the shared lists). This spec only states each tag's tier.
- Call order at the bottom of the script (lines ~571-577): `scan_plugins; scan_plugin_self; scan_ref_graph; scan_memory; scan_output_styles; scan_mcp`.
- The test harness (`tests/test_scripts.sh`): for each `evals/*.json` with `grader.method == code`, copies
  `tests/fixtures/<dir>/` to a temp `target/`, renames `dot-claude` to `.claude`, plants `target/.git`, and runs
  `scan-graph.sh --no-cache target/.claude`. So **CLAUDE_DIR = the fixture's `dot-claude/`** and root-level siblings
  of `dot-claude/` (e.g. `.mcp.json`) land at `CLAUDE_DIR/..`. A **plugin root is audited by putting
  `.claude-plugin/plugin.json` (and any `skills/`, `evals/`, `output-styles/`) inside `dot-claude/`**: the scanner
  treats CLAUDE_DIR as the plugin root. `needs_home_override: true` is only for user-tree checks (`scan_plugins`); none of L5-L8 needs it.
  Locator asserts (`path_substring`) match against the whole normalized line `[TAG] path :: message`, so a message
  fragment works as a locator.
- `expect_clean: true` means the whole tag set (not just the listed tags) must be empty.

## 1. Merge safety: anchors and call-list lines (all four lanes touch one file)

| Lane | Function block goes | Call line goes |
|---|---|---|
| L5 | between the closing `}` of `scan_mcp` and the comment `# Emit \`display<TAB>command\` for every shell command` | one new line `scan_mcp_placement` directly after `scan_mcp` (last call) |
| L6 | **replaces in place** the whole block from the comment `# Output-style hygiene: a settings` through the closing `}` of `scan_output_styles` (lines 405-427). `scan_output_style_files` is defined inside that block and called from `scan_output_styles`, so no call-list edit | none |
| L7 | between `_plugin_shell_commands` and the comment `# Validate a plugin repo's OWN manifest` | one new line `scan_plugin_names` between `scan_plugins` and `scan_plugin_self` |
| L8 | after the closing `}` of `scan_plugin_self`, immediately before `GEN_AT=$(date` | one new line `scan_plugin_evals` between `scan_plugin_self` and `scan_ref_graph` |

Hunks are separated by at least one untouched line each, so a 3-way merge in any order is conflict-free. Final call list:
```
scan_plugins
scan_plugin_names      # L7
scan_plugin_self
scan_plugin_evals      # L8
scan_ref_graph
scan_memory
scan_output_styles     # L6 (internally calls scan_output_style_files)
scan_mcp
scan_mcp_placement     # L5
```
Reference docs: L6 owns `plugin/references/output-styles.md` entirely. L5, L7, L8 each add rows to the Tags table of
`plugin/references/plugin-integrity.md` at distinct spots (L5 after the `MCP-PLAINTEXT-SECRET` row; L7 after the
`PLUGIN-USERCONFIG-IN-SHELL` row, i.e. before `MARKETPLACE-DEAD-SOURCE`; L8 after the `MARKETPLACE-DEAD-SOURCE` row, the table end).
Remediation-order lines, report blocks, and every shared tag list (command file tier lists, `report-format.md`,
`finding-verification.md`, README) are left to L10. Existing eval ids/fixtures are not renamed by these lanes.

---

## 2. Lane L5 - MCP placement (eval ids 165-169)

### Tags
| Tag | Tier | Phase | Fires when |
|---|---|---|---|
| `MCP-MISPLACED` | Critical | 2 | (a) `$CLAUDE_DIR/.mcp.json` exists and CLAUDE_DIR is not a plugin root; (b) project-root `$CLAUDE_DIR/../.mcp.json` has a top-level `servers` and no `mcpServers`; (c) `settings.json` / `settings.local.json` has an `mcpServers` key. In all three the servers silently never load. |
| `MCP-RELATIVE-PATH` | Hygiene | 2 | an `mcpServers` entry in `../.mcp.json` or `../.claude.json` whose `command`/`args` item starts with `./` or `../` (also `--flag=./x`), or whose `command` is a relative path with a slash (`scripts/run.sh`). One finding per server. |

### Doc quotes (debug-your-config.md, "MCP servers" table, lines 53, 110, 111, 113)
- "MCP servers in `.mcp.json` never load | File is under `.claude/`, or its servers sit under a top-level `servers` key, as in VS Code's `mcp.json`, instead of `mcpServers` | Project MCP config goes at the repository root as `.mcp.json`, not inside `.claude/`, with servers under the `mcpServers` key."
- "MCP servers added under `mcpServers` in `settings.json` never appear | `settings.json` does not read an `mcpServers` key | Define project servers in `.mcp.json` at the repository root, or run `claude mcp add --scope user` for user-scoped servers."
- "Relative file paths in `command` or `args` are a frequent cause, since they resolve against the directory you launched Claude Code from rather than the location of `.mcp.json`." and "`command` or `args` uses a relative file path | Use absolute paths for local scripts. Executables on your `PATH` like `npx` or `uvx` work as-is."

### Design decisions
- Plugin roots (CLAUDE_DIR holds `.claude-plugin/plugin.json`): their own `$CLAUDE_DIR/.mcp.json` is the legitimate plugin MCP file (manifest-reference lists `.mcp.json` as a plugin component), so rule (a) is skipped, and the relative-path rule is skipped (the parent dir is not a project root; no doc evidence for plugin relative-path semantics, so stay conservative). Mutation-proofed by fixture 169.
- The existing `scan_mcp` keeps auditing `.claude/.mcp.json` and settings `mcpServers` for BAD-DEF/SSE/secret: a misplaced file can still hold a plaintext secret, so those stay. `MCP-MISPLACED` is additive.
- Relative-path jq regex is passed with `--arg`, so the shell variable must hold SINGLE backslashes (a first prototype used `\\.` and silently matched nothing; eval 168 caught it).
- Bare relative names without slash (`server.js`) are not flagged (indistinguishable from a PATH executable).

### Code (insert at the L5 anchor; prototype verbatim)
```bash
# ── L5: MCP config placement ────────────────────────────────────────────────
#   MCP-MISPLACED      — a config Claude Code never reads: `.claude/.mcp.json`, a project-root
#                        `.mcp.json` whose servers sit under `servers` (VS Code shape) with no
#                        `mcpServers`, or an `mcpServers` key in settings.json/settings.local.json.
#   MCP-RELATIVE-PATH  — `command`/`args` is a relative file path (`./x`, `../x`, `scripts/x`):
#                        it resolves against the launch directory, not against the .mcp.json.
# A plugin root legitimately carries `.mcp.json` at its top, so the `.claude/.mcp.json` rule and the
# relative-path rule are skipped when CLAUDE_DIR holds .claude-plugin/plugin.json.
MCP_RELPATH_RE='^(\.{1,2}/|[A-Za-z0-9_-]+=\.{1,2}/)'
scan_mcp_placement() {
    local plugin_root=0 f sf rel srv val
    [ -f "$CLAUDE_DIR/.claude-plugin/plugin.json" ] && plugin_root=1
    if [ "$plugin_root" = 0 ] && [ -f "$CLAUDE_DIR/.mcp.json" ]; then
        emit_finding 2 "MCP-MISPLACED" ".claude/.mcp.json" "project MCP config sits inside .claude/ — Claude Code reads .mcp.json only at the repository root, so these servers never load"
    fi
    f="$CLAUDE_DIR/../.mcp.json"
    if [ -f "$f" ] && jq -e 'type == "object" and has("servers") and (has("mcpServers") | not)' "$f" >/dev/null 2>&1; then
        emit_finding 2 "MCP-MISPLACED" ".mcp.json" "servers sit under a top-level 'servers' key (VS Code layout) — Claude Code reads only 'mcpServers', so none of them load"
    fi
    for sf in settings.json settings.local.json; do
        f="$CLAUDE_DIR/$sf"
        [ -f "$f" ] || continue
        jq -e 'type == "object" and has("mcpServers")' "$f" >/dev/null 2>&1 \
            && emit_finding 2 "MCP-MISPLACED" "$sf" "'mcpServers' in $sf is never read — define project servers in .mcp.json at the repository root, or run 'claude mcp add --scope user'"
    done
    [ "$plugin_root" = 1 ] && return 0
    for f in "$CLAUDE_DIR/../.mcp.json" "$CLAUDE_DIR/../.claude.json"; do
        [ -f "$f" ] || continue
        rel="${f##*/}"
        while IFS=$'\t' read -r srv val; do
            [ -z "$srv" ] && continue
            emit_finding 2 "MCP-RELATIVE-PATH" "$rel" "MCP server '$srv' uses relative path '$val' — it resolves against the directory Claude Code was launched from, not against $rel; use an absolute path or a PATH executable"
        done < <(jq -r --arg re "$MCP_RELPATH_RE" '
            (.mcpServers // {}) | if type == "object" then . else {} end
            | to_entries[] | select(.value | type == "object") | .key as $k
            | ( [ (.value.command // empty), ((.value.args // []) | if type == "array" then .[] else empty end) ]
                | map(select(type == "string"))
                | map(select(test($re))) ) as $args
            | ( (.value.command // "") | if type == "string" and test("^[A-Za-z0-9_.-]+/") then [.] else [] end ) as $cmd
            | ($args + $cmd) | select(length > 0) | "\($k)\t\(.[0])"' "$f" 2>/dev/null || true)
    done
}

```

Plus the call line `scan_mcp_placement` after `scan_mcp`.

### Fixtures and evals (generator lines in the Appendix; all `needs_home_override: false`)
| Eval id | Fixture dir (`tests/fixtures/...`) | Files in `dot-claude/` (and root) | must_detect | must_not_flag | clean |
|---|---|---|---|---|---|
| 165-mcp-misplaced-claude-dir | mcp-misplaced-claude-dir | `.mcp.json` (valid `mcpServers`), `settings.json` `{}` | MCP-MISPLACED @ `.claude/.mcp.json` | MCP-RELATIVE-PATH, MCP-BAD-DEF | no |
| 166-mcp-misplaced-servers-key | mcp-misplaced-servers-key | root `.mcp.json` with `"servers"`; `settings.json` `{}` | MCP-MISPLACED @ `servers` | - | no |
| 167-mcp-misplaced-settings | mcp-misplaced-settings | `settings.json` with `mcpServers` | MCP-MISPLACED @ `settings.json` | - | no |
| 168-mcp-relative-path | mcp-relative-path | root `.mcp.json`: `local` (node ./server.js), `nested` (scripts/run.sh), `fine-npx`, `fine-abs` (`/usr/local/bin/tool`, `${CLAUDE_PROJECT_DIR}/...`) | MCP-RELATIVE-PATH @ `./server.js` and @ `scripts/run.sh` | MCP-MISPLACED | no |
| 169-mcp-placement-clean | mcp-placement-clean | plugin root: `.claude-plugin/plugin.json` (`mcp-demo`), `.mcp.json` using `${CLAUDE_PLUGIN_ROOT}`, `settings.json`; root `.mcp.json` with `./server.js` | - | MCP-MISPLACED, MCP-RELATIVE-PATH | **yes** |

Measured mutation proofs: removing the plugin-root guard on rule (a) fails 169 (clean + MISPLACED); removing the `return 0` for the relative rule fails 169 (clean + RELATIVE-PATH).
Negative coverage: `fine-npx`/`fine-abs` servers in 168 produce no findings (message-level, `local` and `nested` only).

### Existing fixtures that newly fire
- `tests/fixtures/missing-pre-approved` (eval 27): its `settings.json` carries `mcpServers`, so it now also emits `MCP-MISPLACED` (a true positive: Claude Code does not read that key). Eval 27 has no `expect_clean` and no `must_not_flag` for it, so it stays green with NO edit. Do not edit the fixture (it deliberately models a server declared in settings for `MISSING-PRE-APPROVED`).
- All other fixtures: zero diff in tags (old-vs-new script run over every `tests/fixtures/*` in both HOME modes).

### Dogfood (read-only simulation, old vs new scan-graph.sh)
- `~/.claude`: **1 new hit**, `MCP-MISPLACED .claude/.mcp.json`. True positive: `~/.claude/.mcp.json` (modified June 5) holds a `node9` server that Claude Code never reads. Action for the user, outside this repo: delete it or move to `claude mcp add --scope user`.
- `~/work/intraswitch/.claude`: no change (no `.mcp.json` at `~/work/intraswitch/`).
- `~/work/intraswitch/apps/ng/.claude`: **1 new hit**, `MCP-MISPLACED settings.json`: `settings.json` carries `mcpServers` (chrome-devtools, webstorm sse, angular-cli) that Claude Code ignores; `apps/ng/.mcp.json` only declares `angular-cli`, so chrome-devtools and webstorm are dead there (`~/.claude.json` declares only codegraph and jetbrains; they load only if another scope provides them). True positive; report to the user, do not modify.
- The repo `plugin/` and repo root: no L5 hit.

### Reference doc (`plugin/references/plugin-integrity.md`)
Add two table rows after the `MCP-PLAINTEXT-SECRET` row:
`| \`MCP-MISPLACED\` | an MCP config Claude Code never reads: a \`.mcp.json\` inside \`.claude/\` (not a plugin root), a project-root \`.mcp.json\` whose servers sit under a top-level \`servers\` key instead of \`mcpServers\`, or an \`mcpServers\` key in \`settings.json\`/\`settings.local.json\` | Critical |`
`| \`MCP-RELATIVE-PATH\` | an \`mcpServers\` \`command\`/\`args\` that is a relative path (\`./x\`, \`../x\`, \`dir/x\`): it resolves against the directory Claude Code was launched from, not against \`.mcp.json\`. \`npx\`/\`uvx\`/absolute paths are fine | Hygiene |`
(The existing intro sentence "The plugin-root checks fire only when..." needs no change.)

---

## 3. Lane L6 - output styles: bug fix + frontmatter checks (eval ids 170-179)

### Bug being fixed (existing `OUTPUTSTYLE-MISSING`, lines 405-427)
1. `OUTPUT_STYLE_BUILTINS="default proactive explanatory learning"` lacks `concise`, so a valid `outputStyle: "Concise"` is a false MISSING.
2. The match lower-cases the value (comment: "so the match is case-insensitive"); the docs say the opposite.
3. The lookup is `output-styles/$selected.md` only: a style selected by its frontmatter `name:` is a false MISSING, and a style living in the user tree or an ancestor project is a false MISSING for a project selection.

### Doc quotes (output-styles.md, fetched today)
- Line 9/26: "Claude Code includes four built-in styles besides its default" ; table rows Proactive, **Concise**, Explanatory, Learning ; Concise: "Requires Claude Code v2.1.237 or later."
- Line 110: "The value is case-sensitive, so write the built-in names as `Proactive`, `Concise`, `Explanatory`, and `Learning`. A value that doesn't match a style name exactly, such as `explanatory`, gives you the Default style. The `/output-style` command ignores case."
- Line 124: "The file name becomes the style name unless you set `name` in the frontmatter."
- Line 130: "Project output styles load from every `.claude/output-styles/` between the working directory and the repository root."
- Line 164: "All fields are optional, and field names use lowercase words separated by hyphens. A misspelled field is ignored without an error. If the YAML doesn't parse, the style still loads under its file name with no fields set; run `claude --debug` to see the parse error."
- Line 171: `force-for-plugin` - "Plugin output styles only."

### Changed lines, precisely (diff against current scan-graph.sh)
| Current | New |
|---|---|
| `OUTPUT_STYLE_BUILTINS="default proactive explanatory learning"` | `OUTPUT_STYLE_BUILTINS="Default Proactive Concise Explanatory Learning"` (documented spellings, `Concise` added) |
| `sel_lc=$(printf '%s' "$selected" \| tr '[:upper:]' '[:lower:]')` and `case " $OUTPUT_STYLE_BUILTINS " in *" $sel_lc "*) return 0 ;; esac` | `case " $OUTPUT_STYLE_BUILTINS " in *" $selected "*) return 0 ;; esac` (exact, case-sensitive). `[ "$selected" = "default" ] && return 0` is kept as the one tolerated lowercase spelling, because the fallback it triggers is the Default style itself (and `~/work/intraswitch/.claude/settings.local.json` uses it) |
| `if [ ! -f "$styles_dir/$selected.md" ]; then emit OUTPUTSTYLE-MISSING ...` | collect `names` = `_output_style_name` of every `*.md` in `_output_style_dirs` (scanned tree, `$USER_TREE/output-styles`, and each ancestor `.claude/output-styles` up to the dir holding `.git` or `$HOME`); exact `grep -qxF` match -> clean. Otherwise a case-insensitive hit on a built-in or a style name -> new `OUTPUTSTYLE-CASE` (and NOT MISSING); no hit -> `OUTPUTSTYLE-MISSING` with the reworded message `names no style: it is not a built-in and no output-styles/*.md has that file name or frontmatter name:` (locator `settings` still matches) |
| local `styles_dir` | removed |
| header comment "documented values are capitalized ..., so the match is case-insensitive" | rewritten as in the code block below |

Frontmatter `name:` resolution: `_output_style_frontmatter` (awk: lines between the first two `---`) then `sed -n 's/^name:...'`, quotes stripped, falling back to the file name. A file with `name: terse` is selectable as `terse` only, NOT as its file name (fixture 173).

### New tags
| Tag | Tier | Phase | Fires when |
|---|---|---|---|
| `OUTPUTSTYLE-CASE` | Structural | 26 | the selected value equals a built-in or a style name only case-insensitively (`explanatory`): falls back to Default |
| `OUTPUTSTYLE-UNKNOWN-FIELD` | Hygiene | 26 | a top-level frontmatter key not in `name description keep-coding-instructions force-for-plugin`; did-you-mean when the key equals a field after dropping `_`/`-` and case (`keep_coding_instructions`, `keepCodingInstructions`) |
| `OUTPUTSTYLE-BAD-YAML` | Structural | 26 | frontmatter opens with `---` but never closes; a tab-indented line; or an unquoted plain scalar containing `: ` (the classic `description: Use for review: strict`). Deterministic heuristics (no YAML parser in the toolchain): they catch the common breakages, not every parse error |
| `OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN` | Hygiene | 26 | `force-for-plugin:` in a style file while CLAUDE_DIR is not a plugin root |
`OUTPUTSTYLE-MISSING` stays Critical.

### Code (replaces lines 405-427; prototype verbatim)
```bash
# Output-style hygiene (Phase 26). Runs on any tree.
#   OUTPUTSTYLE-MISSING — `outputStyle` names no style: not a built-in, and no
#                         output-styles/*.md whose frontmatter `name:` (else file name) equals it.
#   OUTPUTSTYLE-CASE    — the value matches a style only case-insensitively. The settings
#                         value is case-sensitive, so Claude Code falls back to Default.
# Built-ins are exactly the documented spellings; `default` (lowercase) is tolerated because the
# fallback it triggers IS the Default style.
OUTPUT_STYLE_BUILTINS="Default Proactive Concise Explanatory Learning"
OUTPUT_STYLE_FIELDS="name description keep-coding-instructions force-for-plugin"

# Frontmatter body (between the first two `---` lines); empty when the file has no fence.
_output_style_frontmatter() {
    awk 'NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; infm = 1; next }
         infm && /^---[[:space:]]*$/ { exit }
         infm { print }' "$1" 2>/dev/null
}

# The style's name: frontmatter `name:` when set, else the file name without .md.
_output_style_name() {
    local n
    n=$(_output_style_frontmatter "$1" | sed -nE 's/^name:[[:space:]]*(.*)$/\1/p' | head -1 \
        | sed -E 's/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' | tr -d '\r')
    if [ -n "$n" ]; then printf '%s\n' "$n"; else basename "$1" .md; fi
}

# Every .claude/output-styles/ Claude Code would load for this tree: the scanned one, the user's,
# and each ancestor project's up to the repository root (docs: "every .claude/output-styles/
# between the working directory and the repository root").
_output_style_dirs() {
    local d
    printf '%s\n' "$CLAUDE_DIR/output-styles" "$USER_TREE/output-styles"
    d=$(cd "$CLAUDE_DIR/.." 2>/dev/null && pwd -P) || return 0
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        printf '%s\n' "$d/.claude/output-styles"
        { [ -e "$d/.git" ] || [ "$d" = "$HOME" ]; } && break
        d=$(dirname "$d")
    done
}

scan_output_styles() {
    local selected="" sf v dir f names="" b hit=""
    scan_output_style_files
    for sf in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
        [ -f "$sf" ] || continue
        v=$(jq -r '.outputStyle // empty' "$sf" 2>/dev/null)
        [ -n "$v" ] && selected="$v"
    done
    [ -n "$selected" ] || return 0
    [ "$selected" = "default" ] && return 0
    case " $OUTPUT_STYLE_BUILTINS " in
        *" $selected "*) return 0 ;;
    esac
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.md; do
            [ -f "$f" ] || continue
            names+="$(_output_style_name "$f")"$'\n'
        done
    done < <(_output_style_dirs)
    if printf '%s' "$names" | grep -qxF -- "$selected"; then
        return 0
    fi
    for b in $OUTPUT_STYLE_BUILTINS; do
        [ "${b,,}" = "${selected,,}" ] && hit="$b"
    done
    [ -z "$hit" ] && hit=$(printf '%s' "$names" | grep -ixF -- "$selected" | head -1)
    if [ -n "$hit" ]; then
        emit_finding 26 "OUTPUTSTYLE-CASE" "settings.json" "outputStyle '$selected' matches style '$hit' only case-insensitively — the value is case-sensitive, so Claude Code falls back to the Default style; write '$hit'"
    else
        emit_finding 26 "OUTPUTSTYLE-MISSING" "settings.json" "outputStyle '$selected' names no style: it is not a built-in and no output-styles/*.md has that file name or frontmatter name:"
    fi
}

#   OUTPUTSTYLE-UNKNOWN-FIELD       — a frontmatter key outside name/description/keep-coding-instructions/
#                                     force-for-plugin: ignored without any error.
#   OUTPUTSTYLE-BAD-YAML            — frontmatter that cannot parse (unclosed fence, tab indent, plain scalar
#                                     containing `: `): the style loads under its file name with no fields.
#   OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN — `force-for-plugin` outside a plugin root is inert.
scan_output_style_files() {
    local f rel fm key norm want suggestion plugin_root=0
    [ -f "$CLAUDE_DIR/.claude-plugin/plugin.json" ] && plugin_root=1
    for f in "$CLAUDE_DIR"/output-styles/*.md; do
        [ -f "$f" ] || continue
        rel="output-styles/${f##*/}"
        head -1 "$f" | grep -qE '^---[[:space:]]*$' || continue
        fm=$(_output_style_frontmatter "$f")
        if ! sed -n '2,$p' "$f" | grep -qE '^---[[:space:]]*$'; then
            emit_finding 26 "OUTPUTSTYLE-BAD-YAML" "$rel" "frontmatter fence is never closed — the style loads under its file name with no fields set (run claude --debug to see the parse error)"
            continue
        fi
        if printf '%s\n' "$fm" | grep -qE $'^[ ]*\t' \
            || printf '%s\n' "$fm" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]+[^"'"'"'|>[{#&*!%@`-][^#]*:[[:space:]]'; then
            emit_finding 26 "OUTPUTSTYLE-BAD-YAML" "$rel" "frontmatter does not parse as YAML (tab indent, or an unquoted value containing ': ') — the style loads under its file name with no fields set"
            continue
        fi
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            case " $OUTPUT_STYLE_FIELDS " in *" $key "*) continue ;; esac
            norm=$(printf '%s' "$key" | tr -d '_-' | tr '[:upper:]' '[:lower:]')
            suggestion=""
            for want in $OUTPUT_STYLE_FIELDS; do
                [ "$(printf '%s' "$want" | tr -d '-')" = "$norm" ] && suggestion=" — did you mean '$want'?"
            done
            emit_finding 26 "OUTPUTSTYLE-UNKNOWN-FIELD" "$rel" "frontmatter key '$key' is not an output-style field and is silently ignored$suggestion"
        done < <(printf '%s\n' "$fm" | sed -nE 's/^([A-Za-z_][A-Za-z0-9_-]*):.*/\1/p')
        if [ "$plugin_root" = 0 ] && printf '%s\n' "$fm" | grep -qE '^force-for-plugin:'; then
            emit_finding 26 "OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN" "$rel" "force-for-plugin only applies to plugin output styles — in a user/project style it has no effect"
        fi
    done
}

```

`scan_output_style_files` runs only on the scanned tree's own `output-styles/` (never the user tree or ancestors), so a project audit does not re-report user-level style files.

### Fixtures and evals (generator in Appendix)
| Eval id | Fixture dir | Contents of `dot-claude/` | must_detect | must_not_flag | clean |
|---|---|---|---|---|---|
| 170-outputstyle-concise-builtin | outputstyle-concise-builtin | `settings.json` `{"outputStyle":"Concise"}` | - | OUTPUTSTYLE-MISSING, OUTPUTSTYLE-CASE | **yes** |
| 171-outputstyle-case | outputstyle-case | `{"outputStyle":"explanatory"}` | OUTPUTSTYLE-CASE @ settings | OUTPUTSTYLE-MISSING | no |
| 172-outputstyle-frontmatter-name | outputstyle-frontmatter-name | `{"outputStyle":"terse"}` + `output-styles/voice-v2.md` with `name: terse` | - | MISSING, CASE | **yes** |
| 173-outputstyle-name-shadowed | outputstyle-name-shadowed | `{"outputStyle":"voice-v2"}` + same `voice-v2.md` (`name: terse`) | OUTPUTSTYLE-MISSING @ voice-v2 | CASE | no |
| 174-outputstyle-unknown-field | outputstyle-unknown-field | `output-styles/loose.md` with `keep_coding_instructions`, `descripton` | UNKNOWN-FIELD @ keep_coding_instructions and @ descripton | BAD-YAML | no |
| 175-outputstyle-bad-yaml | outputstyle-bad-yaml | `colon.md` (`description: Use for review: strict mode`), `unclosed.md` (fence never closed) | BAD-YAML @ colon.md and @ unclosed.md | UNKNOWN-FIELD | no |
| 176-outputstyle-force-outside-plugin | outputstyle-force-outside-plugin | `forced.md` with `force-for-plugin: true` | FORCE-OUTSIDE-PLUGIN @ forced.md | - | no |
| 177-outputstyle-plugin-force-ok | outputstyle-plugin-force-ok | plugin root (`.claude-plugin/plugin.json` `style-demo`) + same `forced.md` | - | FORCE-OUTSIDE-PLUGIN | **yes** |
| 178-outputstyle-styles-clean | outputstyle-styles-clean | `{"outputStyle":"terse"}`, `terse.md` (valid fields, quoted `"Short: answers only."`), `plain.md` (no frontmatter) | - | MISSING, CASE, UNKNOWN-FIELD, BAD-YAML | **yes** |
(179 spare.) All fixtures use `needs_home_override: false`. Because the harness does not override HOME in these, `_output_style_dirs` also reads the REAL `~/.claude/output-styles`; no fixture selects a name that exists there (`terse-verified` is the real one). Keep it that way.

### Existing fixtures: expected outcomes after the fix (must keep working)
- `outputstyle-builtin` (eval 47, `outputStyle: "Explanatory"`, no style files): exact built-in match -> **no finding**; eval 47 (`expect_clean: true`, `must_not_flag OUTPUTSTYLE-MISSING`) stays green. Its `expected_behavior` sentence says "(case-insensitive)"; reword that one string to "treats the documented spelling 'Explanatory' as a valid built-in (the match is case-sensitive)". It is not validated by tests; the id range rule is about NEW evals.
- `outputstyle-missing` (eval 42, `"nonexistent"`): no built-in, no style anywhere (and the real `~/.claude/output-styles` has only `terse-verified`) -> **`OUTPUTSTYLE-MISSING` at `settings.json`**; eval 42 stays green (`path_substring: "settings"`).
- `clean` fixture has `output-styles/concise.md` with no `name:` and a settings that selects nothing: `scan_output_style_files` finds valid/no frontmatter -> no finding (verified by the full-fixture diff: zero new tags).

### Mutation proofs (run)
`Concise` removed -> 170 fails; case-insensitive branch removed -> 171 fails (3 asserts); file-name-only resolution -> 172 fails; plugin-root guard on FORCE removed -> 177 fails.

### Dogfood
- `~/.claude`: `outputStyle: terse-verified`; `output-styles/terse-verified.md` has `description` and `keep-coding-instructions` only, no `name` -> resolves by file name -> **no hit**.
- `~/work/intraswitch/.claude`: `settings.local.json` `outputStyle: "default"` -> tolerated lowercase Default -> **no hit** (without the exemption it would be a harmless-but-noisy OUTPUTSTYLE-CASE).
- `~/work/intraswitch/apps/ng/.claude`, repo `plugin/`, repo root: no style files, no selection -> no hit.

### Reference doc: `plugin/references/output-styles.md` (L6 owns the whole file)
- Source section: replace the built-in bullet with: built-ins are exactly `Default`, `Proactive`, `Concise`, `Explanatory`, `Learning` (Concise needs Claude Code v2.1.237); matching is case-sensitive; a style is named by frontmatter `name:`, else its file name; styles load from the scanned tree, the user tree, and every ancestor `.claude/output-styles/` up to the repository root.
- Tags table: add the four rows above with tiers; reword the `OUTPUTSTYLE-MISSING` condition ("names no style: not a built-in and no `output-styles/*.md` with that file name or frontmatter `name:`").
- Remediation: item 1's built-in list becomes `Default`/`Proactive`/`Concise`/`Explanatory`/`Learning`; add `OUTPUTSTYLE-CASE` -> write the exact spelling; `OUTPUTSTYLE-UNKNOWN-FIELD`/`BAD-YAML` -> fix the key / quote the value or use a block scalar (`description: >`); `OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN` -> remove the key or move the style into a plugin. Also note "style files are read at startup: restart after editing".
- Report block `Styles: N on disk · Selected: <name|none> · Missing: X` unchanged.

---

## 4. Lane L7 - plugin AND marketplace names (eval ids 180-189)

### Tags
| Tag | Tier | Phase | Fires when |
|---|---|---|---|
| `PLUGIN-RESERVED-NAME` | Structural | 2 | `plugin.json#name` or a `marketplace.json#plugins[].name` is an "Error" row of the manifest-reference table (below). `claude plugin init/tag` refuse it; Claude Code still installs and loads it, hence Structural |
| `PLUGIN-NAME-LOOKALIKE` | Hygiene | 2 | the "Warning" row: `claude`/`anthropic`/`anthropics` as a whole word elsewhere (`mcp-for-claude`) |
| `PLUGIN-NAME-FORMAT` | Structural | 2 | empty, or contains whitespace, `@`, `:`, `/`, `\`, a control character; for a marketplace entry also not matching `^[A-Za-z0-9][A-Za-z0-9._-]*$` (plugin-id alphabet) |
| `PLUGIN-NAME-NOT-KEBAB` | Hygiene | 2 | valid but not `^[a-z0-9]+(-[a-z0-9]+)*$` ("Validation passed with warnings: ... a `name` that isn't kebab-case") |
| `MARKETPLACE-NAME-FORMAT` | Critical | 2 | marketplace `name` empty, outside letters/digits/`.`/`_`/`-`, not starting alphanumeric, or containing `..`: nothing can be installed from it |
| `MARKETPLACE-NAME-RESERVED` | Critical | 2 | reserved list (exact, any casing), another spelling of a reserved name, `claudeai-` prefix, non-ASCII, `official` beside claude/anthropic, or `^(claude\|anthropic)-plugins?(-\|$)` |

### Exact rule tables (re-read today)
manifest-reference.md lines 165-178, `name`:
"The plugin identifier. It must be non-empty, with no spaces, `@`, `:`, path separators, control characters, or bidirectional-formatting characters; use kebab-case." / "`claude plugin validate` also checks that the name doesn't pass as one of Anthropic's own plugins. The check ignores case and treats any run of separators as one:"
| Name | Result |
|---|---|
| Starts with `claude-`, `anthropic-`, `anthropics-`, or `cc-plugin-` | Error |
| Is `claude`, `anthropic`, `anthropics`, `claude-code`, or `claude-mods` | Error |
| Puts `official` beside `claude` or `anthropic`, such as `official-claude-tools` | Error |
| Has `claude`, `anthropic`, or `anthropics` as a whole word anywhere else, such as `mcp-for-claude` | Warning |
"`claude plugin init` and `claude plugin tag` refuse a name that draws the error. Only these commands check the name. Claude Code still installs and loads a plugin whose name they refuse."
-> implemented by `_plugin_name_reserved`: lower-case, `[^a-z0-9]+` -> `-`, trim `-` ("ignores case and treats any run of separators as one"); rows 1-2 by `case`, row 3 and 4 by ERE.

marketplace-reference.md line 60, `name`: "Marketplace identifier: letters, digits, `.`, `_`, and `-`, starting with a letter or digit, and no `..`. `claude plugin validate` fails any other name, because Claude Code can't install plugins from a marketplace that uses one." Same file, "Reserved names" (lines 39-50) lists: official `claude-code-marketplace, claude-code-plugins, claude-plugins-official, anthropic-marketplace, anthropic-plugins, agent-skills, anthropic-agent-skills, life-sciences, knowledge-work-plugins, claude-for-legal, claude-for-financial-services, financial-services-plugins, first-party-plugins, claude-tag-plugins` ("Reserved unless the marketplace comes from a `github` or `git` marketplace source under `github.com/anthropics/`"); community `claude-community, claude-plugins-community, healthcare`; directory `anthropic-plugin-directory, claude-plugin-directory`; "Names that impersonate an official marketplace: names such as `official-claude-plugins` or `claude-plugins-v2`, and any name containing a non-ASCII character"; "Another spelling of a reserved name: a name that differs from a reserved name only by a trailing dot, or by a symbol other than an underscore in place of a hyphen, so `claude.code.plugins` counts as `claude-code-plugins`" (v2.1.280); "`inline` ... `builtin` ... `skills-dir` ... and `synced` ... `claude-plugin-test` is also reserved"; "`npm`, `pip`, `uv`, `cargo`, `github`, and `gh`: reserved in any casing" (v2.1.275); "Names starting with `claudeai-`". Entry names: "Plugin name cannot contain spaces. Use kebab-case", "Plugin name "x" is reserved: it passes as one of Anthropic's own" (Error), "reads as one of Anthropic's own" (Warning), and "Each part of a plugin id (plugin@marketplace) may use only the letters a-z and A-Z, digits, ".", "_" and "-", and must start with a letter or digit."

### Decisions and limits (state in the code comments / reference doc)
- Runs when `.claude-plugin/plugin.json` OR `.claude-plugin/marketplace.json` exists in CLAUDE_DIR, so a marketplace-only root is audited (the repo root has only `marketplace.json`; today `scan_plugin_self` returns early there). The existing `MARKETPLACE-DEAD-SOURCE` stays in `scan_plugin_self` (needs plugin.json) and is not touched.
- The `github.com/anthropics/` exemption is not evaluated (no git-remote parsing); the message states it. A maintainer under that org dismisses the finding.
- The impersonation heuristic beyond the doc's literal examples (`official` adjacency, non-ASCII, `^(claude|anthropic)-plugins?(-|$)`) is UNVERIFIED against the real validator: it covers the two documented examples. Do not widen it.
- Missing `name` is not reported (manifest-reference marks it required; `claude plugin validate` already says so); only a present-but-bad string is.
- Deliberately NOT in this lane: duplicate plugin names in one marketplace, Claude-Desktop 128-char warnings.
- Installed plugins in `~/.claude/plugins/` (user tree) are not name-checked; the marketplace chose those names.

### Code (insert at the L7 anchor; prototype verbatim)
```bash
# ── L7: plugin and marketplace names ────────────────────────────────────────
# Rule tables: plugins/manifest-reference#name and plugins/marketplace-reference#reserved-names.
#   PLUGIN-RESERVED-NAME       (Structural) — passes as one of Anthropic's own: prefix claude-/anthropic-/
#                              anthropics-/cc-plugin-, exact claude/anthropic/anthropics/claude-code/
#                              claude-mods, or `official` beside claude/anthropic. claude plugin
#                              init/tag refuse it; install and load still work.
#   PLUGIN-NAME-LOOKALIKE      (Hygiene)    — claude/anthropic/anthropics as a whole word elsewhere (warning).
#   PLUGIN-NAME-FORMAT         (Structural) — empty, or a space, @, :, path separator, control character.
#   PLUGIN-NAME-NOT-KEBAB      (Hygiene)    — valid but not lower-case kebab-case.
#   MARKETPLACE-NAME-FORMAT    (Critical)   — not letters/digits/./_/-, not starting alphanumeric, or contains `..`:
#                              nothing can be installed from it.
#   MARKETPLACE-NAME-RESERVED  (Critical)   — reserved or impersonating name, any casing/spelling variant.
# A marketplace entry's `name` gets the plugin rules plus the plugin-id alphabet.
MKT_RESERVED_NAMES="claude-code-marketplace claude-code-plugins claude-plugins-official anthropic-marketplace anthropic-plugins agent-skills anthropic-agent-skills life-sciences knowledge-work-plugins claude-for-legal claude-for-financial-services financial-services-plugins first-party-plugins claude-tag-plugins claude-community claude-plugins-community healthcare anthropic-plugin-directory claude-plugin-directory inline builtin skills-dir synced claude-plugin-test npm pip uv cargo github gh"

# Prints "error" | "warning" | nothing for a plugin name (normalised: lower case, separator runs -> one `-`).
_plugin_name_reserved() {
    local n
    n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    case "$n" in
        claude|anthropic|anthropics|claude-code|claude-mods) echo error; return ;;
        claude-*|anthropic-*|anthropics-*|cc-plugin-*) echo error; return ;;
    esac
    if printf '%s' "$n" | grep -qE '(^|-)official-(claude|anthropic|anthropics)(-|$)|(^|-)(claude|anthropic|anthropics)-official(-|$)'; then echo error; return; fi
    if printf '%s' "$n" | grep -qE '(^|-)(claude|anthropic|anthropics)(-|$)'; then echo warning; fi
}

# Emits plugin-name findings for $1=name $2=display path $3=1 when the plugin-id alphabet applies (marketplace entry).
_check_plugin_name() {
    local name="$1" where="$2" idrule="${3:-0}" verdict
    if [ -z "$name" ]; then
        emit_finding 2 "PLUGIN-NAME-FORMAT" "$where" "plugin name is empty"; return
    fi
    if printf '%s' "$name" | LC_ALL=C grep -qE '[[:space:]@:/\\[:cntrl:]]'; then
        emit_finding 2 "PLUGIN-NAME-FORMAT" "$where" "plugin name '$name' contains a space, @, :, path separator or control character — use kebab-case"; return
    fi
    if [ "$idrule" = 1 ] && ! printf '%s' "$name" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        emit_finding 2 "PLUGIN-NAME-FORMAT" "$where" "plugin name '$name' is not a valid plugin-id part (letters, digits, '.', '_', '-'; must start alphanumeric) — Claude Code cannot install it"; return
    fi
    verdict=$(_plugin_name_reserved "$name")
    case "$verdict" in
        error)   emit_finding 2 "PLUGIN-RESERVED-NAME" "$where" "plugin name '$name' is reserved: it passes as one of Anthropic's own — claude plugin validate/init/tag report an error" ;;
        warning) emit_finding 2 "PLUGIN-NAME-LOOKALIKE" "$where" "plugin name '$name' reads as one of Anthropic's own (claude/anthropic as a whole word) — claude plugin validate warns" ;;
    esac
    printf '%s' "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' \
        || emit_finding 2 "PLUGIN-NAME-NOT-KEBAB" "$where" "plugin name '$name' is not kebab-case (lower-case words joined by single hyphens)"
}

_check_marketplace_name() {
    local name="$1" where="$2" n r canon
    if [ -z "$name" ]; then
        emit_finding 2 "MARKETPLACE-NAME-FORMAT" "$where" "marketplace name is empty"; return
    fi
    if printf '%s' "$name" | LC_ALL=C grep -qE '[^A-Za-z0-9._-]' \
        || ! printf '%s' "$name" | grep -qE '^[A-Za-z0-9]' \
        || printf '%s' "$name" | grep -qF '..'; then
        # non-ASCII is reported as impersonation by the docs, everything else as a format error
        if [ -n "$(printf '%s' "$name" | LC_ALL=C tr -d '\000-\177')" ]; then
            emit_finding 2 "MARKETPLACE-NAME-RESERVED" "$where" "marketplace name '$name' contains a non-ASCII character — Claude Code treats it as impersonating an official marketplace"
        else
            emit_finding 2 "MARKETPLACE-NAME-FORMAT" "$where" "marketplace name '$name' must use only letters, digits, '.', '_' and '-', start alphanumeric and contain no '..' — Claude Code cannot install plugins from it"
        fi
        return
    fi
    n=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    canon=$(printf '%s' "$n" | sed -E 's/[^a-z0-9_]/-/g; s/-+$//')
    for r in $MKT_RESERVED_NAMES; do
        if [ "$n" = "$r" ]; then
            emit_finding 2 "MARKETPLACE-NAME-RESERVED" "$where" "marketplace name '$name' is reserved (unless the marketplace is hosted under github.com/anthropics/)"; return
        fi
        if [ "$canon" = "$r" ]; then
            emit_finding 2 "MARKETPLACE-NAME-RESERVED" "$where" "marketplace name '$name' is another spelling of reserved name '$r'"; return
        fi
    done
    case "$n" in claudeai-*)
        emit_finding 2 "MARKETPLACE-NAME-RESERVED" "$where" "marketplace names starting with 'claudeai-' are reserved for marketplaces hosted on claude.ai"; return ;;
    esac
    if printf '%s' "$canon" | grep -qE '(^|-)official-(claude|anthropic)(-|$)|(^|-)(claude|anthropic)-official(-|$)|^(claude|anthropic)-plugins?(-|$)'; then
        emit_finding 2 "MARKETPLACE-NAME-RESERVED" "$where" "marketplace name '$name' impersonates an official Anthropic/Claude marketplace"
    fi
}

scan_plugin_names() {
    local pj="$CLAUDE_DIR/.claude-plugin/plugin.json" mp="$CLAUDE_DIR/.claude-plugin/marketplace.json" nm
    if [ -f "$pj" ] && jq -e 'type == "object" and has("name") and (.name | type == "string")' "$pj" >/dev/null 2>&1; then
        _check_plugin_name "$(jq -r '.name' "$pj")" ".claude-plugin/plugin.json" 0
    fi
    [ -f "$mp" ] || return 0
    if jq -e 'type == "object" and (.name | type == "string")' "$mp" >/dev/null 2>&1; then
        _check_marketplace_name "$(jq -r '.name' "$mp")" ".claude-plugin/marketplace.json"
    fi
    while IFS= read -r nm; do
        _check_plugin_name "$nm" ".claude-plugin/marketplace.json" 1
    done < <(jq -r '(.plugins // []) | if type == "array" then .[] else empty end | select(type == "object" and (.name | type == "string")) | .name' "$mp" 2>/dev/null || true)
}

```

Call line `scan_plugin_names` between `scan_plugins` and `scan_plugin_self`.

### Detection tested against sample names in /tmp (read-only; function bodies sourced from the snippet)
```
plugin: claude-markdown-health-check -> PLUGIN-RESERVED-NAME      plugin: markdown-health-check -> (none)
plugin: Claude Tools   -> PLUGIN-NAME-FORMAT                      plugin: x@y -> PLUGIN-NAME-FORMAT
plugin: official-anthropic -> PLUGIN-RESERVED-NAME                plugin: my_tool -> PLUGIN-NAME-NOT-KEBAB
plugin: claudius       -> (none)                                  normalised: Anthropic_Tools -> error, claude -> error,
claude-code -> error, official-claude-tools -> error, mcp-for-claude -> warning, cc-plugin-x -> error, claude.helper -> error, my_claude_tool -> warning
mkt: ncoevoet-health-check -> (none)       mkt: claude-plugins-official -> RESERVED     mkt: Claude.Code.Plugins -> RESERVED (spelling of claude-code-plugins)
mkt: claudeai-x -> RESERVED                 mkt: skills-dir -> RESERVED                  mkt: NPM -> RESERVED (any casing)
mkt: team.tools_2026 -> (none)              mkt: official-claude-plugins -> RESERVED     mkt: claude-plugins-v2 -> RESERVED
mkt: "bad name" -> FORMAT                   mkt: ünï -> RESERVED (non-ASCII)             mkt: a..b -> FORMAT       mkt: _x -> FORMAT
```

### Fixtures and evals (all `dot-claude/.claude-plugin/...`, `needs_home_override: false`)
| Eval id | Fixture | Manifest content | must_detect | must_not_flag | clean |
|---|---|---|---|---|---|
| 180-plugin-name-reserved-prefix | plugin-name-reserved-prefix | plugin.json `name: "claude-helper"` | PLUGIN-RESERVED-NAME @ plugin.json | LOOKALIKE, FORMAT | no |
| 181-plugin-name-reserved-variants | plugin-name-reserved-variants | `name: "Anthropic_Tools"` | PLUGIN-RESERVED-NAME, PLUGIN-NAME-NOT-KEBAB | - | no |
| 182-plugin-name-lookalike | plugin-name-lookalike | `name: "mcp-for-claude"` | PLUGIN-NAME-LOOKALIKE | PLUGIN-RESERVED-NAME | no |
| 183-plugin-name-format | plugin-name-format | `name: "my plugin@acme"` | PLUGIN-NAME-FORMAT | PLUGIN-RESERVED-NAME | no |
| 184-plugin-name-clean | plugin-name-clean | plugin `claudius-tools`; marketplace `team.tools_2026` with entries `claudius-tools`, `markdown-health-check` (`source: "./"`) | - | all six name tags | **yes** |
| 185-marketplace-name-reserved | marketplace-name-reserved | marketplace.json ONLY (no plugin.json), `name: claude-plugins-official` | MARKETPLACE-NAME-RESERVED | MARKETPLACE-NAME-FORMAT | no |
| 186-marketplace-name-spelling | marketplace-name-spelling | `name: claude.code.plugins` | MARKETPLACE-NAME-RESERVED | FORMAT | no |
| 187-marketplace-name-format | marketplace-name-format | `name: "my marketplace"` | MARKETPLACE-NAME-FORMAT | RESERVED | no |
| 188-marketplace-entry-names | marketplace-entry-names | marketplace `acme-tools`, entries `anthropic-helper`, `ship@it` | PLUGIN-RESERVED-NAME, PLUGIN-NAME-FORMAT @ marketplace.json | MARKETPLACE-NAME-* | no |
| 189-marketplace-inline-reserved | marketplace-inline-reserved | `name: "Inline"` | MARKETPLACE-NAME-RESERVED | - | no |
Fixture 180 deliberately uses `claude-helper`, NOT the repo's own name, so L9's final `grep` for the old name `claude-markdown-health-check` stays clean. Fixture 184 contains the NEW name `markdown-health-check` as the clean positive. Mutation proof run: removing the prefix rule fails 180 (3 asserts).

### Existing fixtures that newly fire
None. (Every existing plugin fixture names its plugin `demo`, `clean-demo`, `path-keys-demo`, etc.; verified by the old-vs-new diff over all fixtures.) `tests/fixtures/clean` has a `marketplace.json`; its names did not fire.

### Dogfood
- `~/.claude`, `~/work/intraswitch/.claude`, `~/work/intraswitch/apps/ng/.claude`: no `.claude-plugin/` -> no hit.
- Repo `plugin/` (current): **`PLUGIN-RESERVED-NAME .claude-plugin/plugin.json`** for `claude-markdown-health-check` (true positive: starts with `claude-`).
- Repo root: **`PLUGIN-RESERVED-NAME .claude-plugin/marketplace.json`** for the entry named `claude-markdown-health-check` (true positive). The marketplace name `ncoevoet-health-check` is clean (no hit).
- After L9 renames both to `markdown-health-check` (plugin.json `name`, marketplace entry `name`): both hits disappear; `markdown-health-check` normalises to itself and trips none of the four rows. L9's verification must re-run `scan-graph.sh --no-cache plugin/` and `scan-graph.sh --no-cache .` and expect zero findings from these tags (also fixture 184 proves the new name is clean). To dogfood the repo root, point the scanner at the repo root explicitly: `scan-graph.sh --no-cache .`.

### Reference doc
`plugin/references/plugin-integrity.md`: add six rows after the `PLUGIN-USERCONFIG-IN-SHELL` row (tiers as above), with the two doc tables summarised and the sentence "The `github.com/anthropics/` exemption is not evaluated". Update the intro sentence "The plugin-root checks fire only when ..." to "...a `.claude-plugin/plugin.json`, or (for the marketplace-name checks) a `.claude-plugin/marketplace.json`".

---

## 5. Lane L8 - plugin eval suite structure (eval ids 190-194)

### Tags
| Tag | Tier | Phase | Fires when |
|---|---|---|---|
| `EVAL-CASE-NO-GRADER` | Structural | 2 | a case directory (holds `prompt.md` or `case.yaml`; outermost only; `results/` and top-level `mocks/` skipped) has neither `graders/*.md` nor a non-empty top-level `graders:` list in `case.yaml` |
| `EVAL-NO-SKILL-GRADER` | Hygiene | 2 | the suite has >= 1 case, and a model-invocable `skills/<name>/SKILL.md` (no `disable-model-invocation: true`) is named by no grader file that has `type: tool_used` and `tool: Skill` (the name must appear in that file, e.g. in `input_match`; case.yaml-inline graders are matched file-wide, a coarse check) |
| `PLUGIN-NO-EVALS` | Discovery | 2 | plugin root with >= 1 model-invocable skill and no eval case in the eval dir (an `evals/` holding only another tool's JSON counts as no suite) |
Gate: `.claude-plugin/plugin.json` must exist in CLAUDE_DIR (plugin root). Eval dir: `experimental.evals` (first entry if an array, optional leading `./`, plain relative dir names, no `..`/absolute; an unusable value falls back to `evals/` exactly as the docs say) else `evals/`. Commands (`commands/*.md`) are not counted as skills: the doc tests "a request one of its skills should handle". (The repo's own `plugin/` ships only a command, so it does not trigger `PLUGIN-NO-EVALS`; the repo's dev `evals/*.json` sit at the repo root, outside the plugin root, and are a different schema.)

### Doc quotes (plugin-evals.md, re-read today)
- Line 127: "A case is a directory under the plugin's eval directory that contains a `prompt.md`, a `case.yaml`, or both. Give each case at least one grader, as a `graders/<name>.md` file or a `graders:` entry in `case.yaml`, because a case without one fails to load. To group cases, nest them under a directory that isn't itself a case; anything inside a case directory, such as `graders/` and fixture files, belongs to that case."
- Line 511: "A directory counts as a case when it holds a `prompt.md` or a `case.yaml`, and a case without at least one grader fails to load with an `invalid case.yaml` error that names `graders`."
- Line 111: "The most common first finding is a `Δ` near zero with the case's `tool_used: Skill` grader failing, which means Claude isn't choosing your skill on natural phrasing." Line 188: the skill-fired grader (`type: tool_used`, `tool: Skill`, `input_match: '"skill"\s*:\s*"(?:[\w-]+:)?your-skill-name"'`) "replacing `your-skill-name` with the skill's directory name under `skills/`".
- Line 261: "In `plugin.json`: add `"experimental": { "evals": "quality/evals" }`." Line 264: "An absolute path or one containing `..` isn't accepted: ... an unusable manifest value prints a `Warning:` line and the run uses `evals/` instead." manifest-reference line 398: "With an array, only the first entry is used."
- Line 632 (troubleshooting heading "plugin eval is currently in early access"): the reason `PLUGIN-NO-EVALS` is Discovery, never a defect.

### Code (insert at the L8 anchor; prototype verbatim)
```bash
# ── L8: plugin eval suite (claude plugin eval) ──────────────────────────────
# Doc: plugin-evals. A case is a directory under the eval dir holding prompt.md and/or case.yaml;
# it needs >= 1 grader (graders/<name>.md or a `graders:` entry in case.yaml) or it fails to load.
#   EVAL-CASE-NO-GRADER  (Structural) — a case directory with no grader.
#   EVAL-NO-SKILL-GRADER (Hygiene)    — the suite has cases, yet no `type: tool_used` + `tool: Skill`
#                                       grader names a model-invocable skill of the plugin.
#   PLUGIN-NO-EVALS      (Discovery)  — plugin ships a model-invocable skill but its eval dir holds no case.
# Eval dir: experimental.evals (first entry when an array; plain relative dir names, no `..`, optional
# leading ./) else `evals/`. An unusable manifest value falls back to evals/, as claude plugin eval does.
# Runs only when CLAUDE_DIR is a plugin root (.claude-plugin/plugin.json).
_plugin_eval_dir() {
    local pj="$CLAUDE_DIR/.claude-plugin/plugin.json" v
    v=$(jq -r '(.experimental // {}) | if type == "object" then .evals else null end
               | if type == "array" then .[0] else . end | select(type == "string")' "$pj" 2>/dev/null || true)
    v="${v#./}"; v="${v%/}"
    case "$v" in ""|/*|..|../*|*/..|*/../*) v="evals" ;; esac
    printf '%s\n' "$v"
}

# A case dir has graders when graders/*.md exists or case.yaml carries a non-empty top-level `graders:`.
_eval_case_has_grader() {
    local c="$1" g
    for g in "$c"/graders/*.md; do [ -f "$g" ] && return 0; done
    [ -f "$c/case.yaml" ] || return 1
    awk '/^graders:[[:space:]]*(#.*)?$/ { inl = 1; next }
         /^graders:[[:space:]]*\[[[:space:]]*\]/ { exit 1 }
         /^graders:[[:space:]]*[^[:space:]#]/ { found = 1; exit }
         inl && /^[[:space:]]*-[[:space:]]/ { found = 1; exit }
         inl && /^[^[:space:]#-]/ { inl = 0 }
         END { exit(found ? 0 : 1) }' "$c/case.yaml"
}

scan_plugin_evals() {
    local pj="$CLAUDE_DIR/.claude-plugin/plugin.json" edir_rel edir c p nested cases="" case_n=0 skill sname sk_files gf
    [ -f "$pj" ] || return 0
    edir_rel=$(_plugin_eval_dir)
    edir="$CLAUDE_DIR/$edir_rel"
    local have_skills=0
    for skill in "$CLAUDE_DIR"/skills/*/SKILL.md; do
        [ -f "$skill" ] && ! grep -qE '^disable-model-invocation:[[:space:]]*true' "$skill" && have_skills=1
    done
    if [ -d "$edir" ]; then
        while IFS= read -r c; do
            case "$c" in "$edir/results"/*|"$edir/mocks"/*) continue ;; esac
            # nested inside an earlier case: it belongs to that case, not a case of its own
            nested=0
            while IFS= read -r p; do
                [ -n "$p" ] && [[ "$c" == "$p"/* ]] && nested=1
            done <<<"$cases"
            [ "$nested" = 1 ] && continue
            cases+="$c"$'\n'; case_n=$((case_n + 1))
        done < <(find "$edir" \( -name prompt.md -o -name case.yaml \) -type f -printf '%h\n' 2>/dev/null | sort -u)
    fi
    if [ "$case_n" = 0 ]; then
        [ "$have_skills" = 1 ] \
            && emit_finding 2 "PLUGIN-NO-EVALS" ".claude-plugin/plugin.json" "plugin ships skills but $edir_rel/ holds no eval case (a <case>/prompt.md or case.yaml) — claude plugin eval has nothing to run, so skill triggering is untested"
        return 0
    fi
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        _eval_case_has_grader "$c" \
            || emit_finding 2 "EVAL-CASE-NO-GRADER" "${c#$CLAUDE_DIR/}" "eval case has no grader (graders/<name>.md or a graders: entry in case.yaml) — claude plugin eval fails to load it"
    done <<<"$cases"
    # every grader file of the suite: graders/*.md plus case.yaml
    sk_files=$(find "$edir" \( -path '*/graders/*.md' -o -name case.yaml \) -type f 2>/dev/null | sort)
    for skill in "$CLAUDE_DIR"/skills/*/SKILL.md; do
        [ -f "$skill" ] || continue
        grep -qE '^disable-model-invocation:[[:space:]]*true' "$skill" && continue
        sname=$(basename "$(dirname "$skill")")
        local named=0
        while IFS= read -r gf; do
            [ -z "$gf" ] && continue
            grep -qE '^[[:space:]-]*type:[[:space:]]*tool_used' "$gf" \
                && grep -qE '^[[:space:]-]*tool:[[:space:]]*"?Skill"?[[:space:]]*$' "$gf" \
                && grep -qF -- "$sname" "$gf" && { named=1; break; }
        done <<<"$sk_files"
        [ "$named" = 1 ] \
            || emit_finding 2 "EVAL-NO-SKILL-GRADER" "skills/$sname/SKILL.md" "no eval grader (type: tool_used, tool: Skill) names skill '$sname' — the suite cannot show Claude picks it on natural phrasing"
    done
}

```

Call line `scan_plugin_evals` between `scan_plugin_self` and `scan_ref_graph`.

### Fixtures and evals
| Eval id | Fixture | Contents of `dot-claude/` | must_detect | must_not_flag | clean |
|---|---|---|---|---|---|
| 190-eval-case-no-grader | eval-case-no-grader | plugin.json (`eval-demo`), `skills/triage/SKILL.md`, `evals/ungraded/prompt.md`, `evals/graded/prompt.md` + `graded/graders/skill-fired.md` (tool_used Skill naming triage) | EVAL-CASE-NO-GRADER @ `evals/ungraded` | EVAL-NO-SKILL-GRADER, PLUGIN-NO-EVALS | no |
| 191-eval-no-skill-grader | eval-no-skill-grader | same plugin, one case with only an `llm` grader | EVAL-NO-SKILL-GRADER @ `skills/triage` | EVAL-CASE-NO-GRADER, PLUGIN-NO-EVALS | no |
| 192-eval-suite-clean | eval-suite-clean | skills `triage` and `deploy` (`disable-model-invocation: true`); case graded via `case.yaml` `graders:` list naming triage; `evals/results/<ts>/aggregate-result.json`; `evals/mocks/server/tool.md` | - | the three eval tags | **yes** |
| 193-plugin-no-evals | plugin-no-evals | skill `triage`; `evals/other-tool-case.json` only | PLUGIN-NO-EVALS @ plugin.json | EVAL-CASE-NO-GRADER, EVAL-NO-SKILL-GRADER | no |
| 194-eval-dir-experimental | eval-dir-experimental | `plugin.json` has `"experimental": {"evals": "./quality/evals"}`; `quality/evals/ungraded/prompt.md`; no `evals/` | EVAL-CASE-NO-GRADER @ `quality/evals/ungraded` | PLUGIN-NO-EVALS | no |
Mutation proof run: removing the `disable-model-invocation` exemption fails 192 (clean + EVAL-NO-SKILL-GRADER).

### Existing fixtures that newly fire
- `tests/fixtures/clean` (eval 01, `expect_clean: true`): plugin root with `skills: "."` and `skills/welltuned/SKILL.md`. **First prototype failed here** (`PLUGIN-NO-EVALS`). Resolution built into the code: skills with `disable-model-invocation: true` (welltuned has it) are not counted as "ships a skill", because Claude never chooses them and so has no trigger to eval. No fixture edit. Any lane builder who drops that filter breaks eval 01.
- Every other plugin fixture (`plugin-*`, `marketplace-*`, `agent-plugin-forbidden`, ...): no diff.

### Dogfood
- No `.claude-plugin/plugin.json` under `~/.claude`, `~/work/intraswitch/.claude`, `~/work/intraswitch/apps/ng/.claude` -> no L8 hit.
- Repo `plugin/`: no `skills/`, no evals -> no L8 hit (and `PLUGIN-NO-EVALS` not triggered since only a command ships). Repo root has no plugin.json -> skipped.

### Reference doc
`plugin/references/plugin-integrity.md`: three rows after the `MARKETPLACE-DEAD-SOURCE` row (the table end). Mention the `/skill-doctor` / `claude plugin details` runtime cross-check only as prose in L10 if wanted.

---

## 6. Cross-lane verification checklist (orchestrator, after merging L5-L8 in any order)
1. `bash tests/run.sh` -> 0 failures. Expected eval count 126 + 29 = 155 (`validate-evals.sh: 155 case(s) valid`) when only L5-L8 are merged; each lane alone adds 5 / 9 / 10 / 5.
2. `shellcheck -S warning plugin/commands/scripts/scan-graph.sh` clean (the merged prototype is clean).
3. Old-vs-new diff over all `tests/fixtures/*` in both HOME modes: the only tag change on an existing fixture is `MCP-MISPLACED` on `missing-pre-approved`.
4. After L9: `plugin/` and repo-root scans free of `PLUGIN-RESERVED-NAME`.
5. A builder editing a lane must not run `tests/run.sh` against the real HOME `output-styles/` assumptions (see L6 note on fixtures selecting names).

## Appendix: fixture + eval generator (prototype; run as `bash mkfx.sh <repo>` to create all 29 evals and fixtures)
Each eval JSON follows the exact shape of `evals/12-plugin-broken-ref.json` (`id`, `command`, `fixture{kind,dir,needs_home_override,scanners}`, `grader{method:code}`, `success_criteria{must_detect,must_not_flag,expect_clean}`, `expected_behavior[]`); `command` is `claude-markdown-health-check` until L9 sed-renames it. Builders can copy the generator from `/tmp/l58/mkfx.sh` (volatile) or re-create from the tables above; its content:
```bash
#!/usr/bin/env bash
# Creates the L5-L8 fixtures + evals under $1 (a repo copy).
R="$1"; F="$R/tests/fixtures"; E="$R/evals"
w() { mkdir -p "$(dirname "$1")"; cat >"$1"; }
# eval writer: ev <id> <dir> <detect-json-array> <not-flag-json-array> <clean> <behavior>
ev() { w "$E/$1.json" <<EOF
{
  "id": "$1",
  "command": "claude-markdown-health-check",
  "fixture": {
    "kind": "claude-tree",
    "dir": "tests/fixtures/$2",
    "needs_home_override": false,
    "scanners": ["scan-graph"]
  },
  "grader": { "method": "code" },
  "success_criteria": {
    "must_detect": $3,
    "must_not_flag": $4,
    "expect_clean": $5
  },
  "expected_behavior": [
    "$6"
  ]
}
EOF
}
SRV='{ "mcpServers": { "docs": { "type": "http", "url": "https://example.com/mcp" } } }'
# ---- L5
echo "$SRV" | w $F/mcp-misplaced-claude-dir/dot-claude/.mcp.json
echo '{}' | w $F/mcp-misplaced-claude-dir/dot-claude/settings.json
ev 165-mcp-misplaced-claude-dir mcp-misplaced-claude-dir '[ { "tag": "MCP-MISPLACED", "path_substring": ".claude/.mcp.json" } ]' '["MCP-RELATIVE-PATH","MCP-BAD-DEF"]' false "scan-graph.sh emits [MCP-MISPLACED] for a .mcp.json sitting inside .claude/, which Claude Code never reads (project MCP config is read only from the repository root)"
echo '{ "servers": { "docs": { "type": "http", "url": "https://example.com/mcp" } } }' | w $F/mcp-misplaced-servers-key/.mcp.json
echo '{}' | w $F/mcp-misplaced-servers-key/dot-claude/settings.json
ev 166-mcp-misplaced-servers-key mcp-misplaced-servers-key '[ { "tag": "MCP-MISPLACED", "path_substring": "servers" } ]' '[]' false "scan-graph.sh emits [MCP-MISPLACED] for a root .mcp.json whose servers sit under a top-level 'servers' key (VS Code layout) with no 'mcpServers'"
echo '{ "mcpServers": { "docs": { "type": "http", "url": "https://example.com/mcp" } } }' | w $F/mcp-misplaced-settings/dot-claude/settings.json
ev 167-mcp-misplaced-settings mcp-misplaced-settings '[ { "tag": "MCP-MISPLACED", "path_substring": "settings.json" } ]' '[]' false "scan-graph.sh emits [MCP-MISPLACED] for an mcpServers key in settings.json, which Claude Code does not read"
w $F/mcp-relative-path/.mcp.json <<'EOF'
{
  "mcpServers": {
    "local": { "command": "node", "args": ["./server.js"] },
    "nested": { "command": "scripts/run.sh" },
    "fine-npx": { "command": "npx", "args": ["-y", "some-mcp-server"] },
    "fine-abs": { "command": "/usr/local/bin/tool", "args": ["--config", "${CLAUDE_PROJECT_DIR}/mcp.toml"] }
  }
}
EOF
echo '{}' | w $F/mcp-relative-path/dot-claude/settings.json
ev 168-mcp-relative-path mcp-relative-path '[ { "tag": "MCP-RELATIVE-PATH", "path_substring": "./server.js" }, { "tag": "MCP-RELATIVE-PATH", "path_substring": "scripts/run.sh" } ]' '["MCP-MISPLACED"]' false "scan-graph.sh emits [MCP-RELATIVE-PATH] for the 'local' (./server.js) and 'nested' (scripts/run.sh) servers, and nothing for the npx / absolute-path / \${CLAUDE_PROJECT_DIR} servers"
# 169: plugin root (its own .mcp.json is legitimate) + valid project-root .mcp.json
echo '{ "mcpServers": { "docs": { "command": "node", "args": ["./server.js"] } } }' | w $F/mcp-placement-clean/.mcp.json
echo '{ "name": "mcp-demo", "version": "1.0.0", "description": "Plugin root whose own .mcp.json is legitimate." }' | w $F/mcp-placement-clean/dot-claude/.claude-plugin/plugin.json
echo '{ "mcpServers": { "bundled": { "command": "${CLAUDE_PLUGIN_ROOT}/bin/server", "args": [] } } }' | w $F/mcp-placement-clean/dot-claude/.mcp.json
echo '{}' | w $F/mcp-placement-clean/dot-claude/settings.json
ev 169-mcp-placement-clean mcp-placement-clean '[]' '["MCP-MISPLACED","MCP-RELATIVE-PATH"]' true "scan-graph.sh stays silent: a plugin root may carry .mcp.json at its top, and the parent .mcp.json (relative ./server.js) is not a project root when the scanned tree is a plugin root"
# ---- L6
echo '{ "outputStyle": "Concise" }' | w $F/outputstyle-concise-builtin/dot-claude/settings.json
ev 170-outputstyle-concise-builtin outputstyle-concise-builtin '[]' '["OUTPUTSTYLE-MISSING","OUTPUTSTYLE-CASE"]' true "scan-graph.sh treats 'Concise' (built-in since Claude Code v2.1.237) as valid"
echo '{ "outputStyle": "explanatory" }' | w $F/outputstyle-case/dot-claude/settings.json
ev 171-outputstyle-case outputstyle-case '[ { "tag": "OUTPUTSTYLE-CASE", "path_substring": "settings" } ]' '["OUTPUTSTYLE-MISSING"]' false "scan-graph.sh emits [OUTPUTSTYLE-CASE] because 'explanatory' matches the built-in 'Explanatory' only case-insensitively, so Claude Code falls back to Default; it must NOT also emit OUTPUTSTYLE-MISSING"
echo '{ "outputStyle": "terse" }' | w $F/outputstyle-frontmatter-name/dot-claude/settings.json
printf -- '---\nname: terse\ndescription: Short answers.\n---\nBe brief.\n' | w $F/outputstyle-frontmatter-name/dot-claude/output-styles/voice-v2.md
ev 172-outputstyle-frontmatter-name outputstyle-frontmatter-name '[]' '["OUTPUTSTYLE-MISSING","OUTPUTSTYLE-CASE"]' true "scan-graph.sh resolves the style by its frontmatter name: (terse), not by the file name voice-v2.md"
echo '{ "outputStyle": "voice-v2" }' | w $F/outputstyle-name-shadowed/dot-claude/settings.json
printf -- '---\nname: terse\ndescription: Short answers.\n---\nBe brief.\n' | w $F/outputstyle-name-shadowed/dot-claude/output-styles/voice-v2.md
ev 173-outputstyle-name-shadowed outputstyle-name-shadowed '[ { "tag": "OUTPUTSTYLE-MISSING", "path_substring": "voice-v2" } ]' '["OUTPUTSTYLE-CASE"]' false "scan-graph.sh emits [OUTPUTSTYLE-MISSING]: the file name stops being the style name once frontmatter sets name: terse, so 'voice-v2' selects nothing"
echo '{}' | w $F/outputstyle-unknown-field/dot-claude/settings.json
printf -- '---\ndescription: ok\nkeep_coding_instructions: true\ndescripton: typo\n---\nBe brief.\n' | w $F/outputstyle-unknown-field/dot-claude/output-styles/loose.md
ev 174-outputstyle-unknown-field outputstyle-unknown-field '[ { "tag": "OUTPUTSTYLE-UNKNOWN-FIELD", "path_substring": "keep_coding_instructions" }, { "tag": "OUTPUTSTYLE-UNKNOWN-FIELD", "path_substring": "descripton" } ]' '["OUTPUTSTYLE-BAD-YAML"]' false "scan-graph.sh emits [OUTPUTSTYLE-UNKNOWN-FIELD] for keep_coding_instructions (did-you-mean keep-coding-instructions) and the descripton typo; description is valid"
echo '{}' | w $F/outputstyle-bad-yaml/dot-claude/settings.json
printf -- '---\ndescription: Use for review: strict mode\n---\nBe strict.\n' | w $F/outputstyle-bad-yaml/dot-claude/output-styles/colon.md
printf -- '---\nname: open\ndescription: never closed\nBody starts here.\n' | w $F/outputstyle-bad-yaml/dot-claude/output-styles/unclosed.md
ev 175-outputstyle-bad-yaml outputstyle-bad-yaml '[ { "tag": "OUTPUTSTYLE-BAD-YAML", "path_substring": "colon.md" }, { "tag": "OUTPUTSTYLE-BAD-YAML", "path_substring": "unclosed.md" } ]' '["OUTPUTSTYLE-UNKNOWN-FIELD"]' false "scan-graph.sh emits [OUTPUTSTYLE-BAD-YAML] for an unquoted value containing ': ' and for a never-closed frontmatter fence"
echo '{}' | w $F/outputstyle-force-outside-plugin/dot-claude/settings.json
printf -- '---\nname: forced\nforce-for-plugin: true\n---\nBe forced.\n' | w $F/outputstyle-force-outside-plugin/dot-claude/output-styles/forced.md
ev 176-outputstyle-force-outside-plugin outputstyle-force-outside-plugin '[ { "tag": "OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN", "path_substring": "forced.md" } ]' '[]' false "scan-graph.sh emits [OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN]: force-for-plugin in a non-plugin tree is inert"
echo '{ "name": "style-demo", "version": "1.0.0", "description": "Plugin shipping a forced output style." }' | w $F/outputstyle-plugin-force-ok/dot-claude/.claude-plugin/plugin.json
printf -- '---\nname: forced\nforce-for-plugin: true\n---\nBe forced.\n' | w $F/outputstyle-plugin-force-ok/dot-claude/output-styles/forced.md
ev 177-outputstyle-plugin-force-ok outputstyle-plugin-force-ok '[]' '["OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN"]' true "scan-graph.sh stays silent: force-for-plugin is legitimate inside a plugin root"
echo '{ "outputStyle": "terse" }' | w $F/outputstyle-styles-clean/dot-claude/settings.json
printf -- '---\nname: terse\ndescription: "Short: answers only."\nkeep-coding-instructions: true\n---\nBe brief.\n' | w $F/outputstyle-styles-clean/dot-claude/output-styles/terse.md
printf -- 'No frontmatter at all, still a valid style.\n' | w $F/outputstyle-styles-clean/dot-claude/output-styles/plain.md
ev 178-outputstyle-styles-clean outputstyle-styles-clean '[]' '["OUTPUTSTYLE-MISSING","OUTPUTSTYLE-CASE","OUTPUTSTYLE-UNKNOWN-FIELD","OUTPUTSTYLE-BAD-YAML"]' true "scan-graph.sh stays silent on valid frontmatter (a quoted value containing ': ' parses), a style with no frontmatter, and a selection that matches a style name"
# ---- L7
pj() { printf '{ "name": "%s", "version": "1.0.0", "description": "fixture" }\n' "$2" | w "$F/$1/dot-claude/.claude-plugin/plugin.json"; }
pj plugin-name-reserved-prefix "claude-helper"
ev 180-plugin-name-reserved-prefix plugin-name-reserved-prefix '[ { "tag": "PLUGIN-RESERVED-NAME", "path_substring": "plugin.json" } ]' '["PLUGIN-NAME-LOOKALIKE","PLUGIN-NAME-FORMAT"]' false "scan-graph.sh emits [PLUGIN-RESERVED-NAME]: a plugin name starting with claude- is an Error row of the manifest-reference name table"
pj plugin-name-reserved-variants "Anthropic_Tools"
ev 181-plugin-name-reserved-variants plugin-name-reserved-variants '[ { "tag": "PLUGIN-RESERVED-NAME", "path_substring": "plugin.json" }, { "tag": "PLUGIN-NAME-NOT-KEBAB", "path_substring": "plugin.json" } ]' '[]' false "scan-graph.sh normalises case and separator runs (Anthropic_Tools -> anthropic-tools) before applying the reserved-name table, and also reports the non-kebab-case spelling"
pj plugin-name-lookalike "mcp-for-claude"
ev 182-plugin-name-lookalike plugin-name-lookalike '[ { "tag": "PLUGIN-NAME-LOOKALIKE", "path_substring": "plugin.json" } ]' '["PLUGIN-RESERVED-NAME"]' false "scan-graph.sh emits [PLUGIN-NAME-LOOKALIKE] (the whole-word Warning row) but not PLUGIN-RESERVED-NAME"
pj plugin-name-format "my plugin@acme"
ev 183-plugin-name-format plugin-name-format '[ { "tag": "PLUGIN-NAME-FORMAT", "path_substring": "plugin.json" } ]' '["PLUGIN-RESERVED-NAME"]' false "scan-graph.sh emits [PLUGIN-NAME-FORMAT] for a name containing a space and @"
pj plugin-name-clean "claudius-tools"
w $F/plugin-name-clean/dot-claude/.claude-plugin/marketplace.json <<'EOF'
{
  "name": "team.tools_2026",
  "owner": { "name": "Team" },
  "plugins": [
    { "name": "claudius-tools", "source": "./" },
    { "name": "markdown-health-check", "source": "./" }
  ]
}
EOF
ev 184-plugin-name-clean plugin-name-clean '[]' '["PLUGIN-RESERVED-NAME","PLUGIN-NAME-LOOKALIKE","PLUGIN-NAME-FORMAT","PLUGIN-NAME-NOT-KEBAB","MARKETPLACE-NAME-FORMAT","MARKETPLACE-NAME-RESERVED"]' true "scan-graph.sh stays silent: claudius is not the whole word claude; markdown-health-check and a marketplace named team.tools_2026 follow every name rule"
mk() { printf '{ "name": "%s", "owner": { "name": "Team" }, "plugins": [ %s ] }\n' "$2" "$3" | w "$F/$1/dot-claude/.claude-plugin/marketplace.json"; }
mk marketplace-name-reserved "claude-plugins-official" ''
ev 185-marketplace-name-reserved marketplace-name-reserved '[ { "tag": "MARKETPLACE-NAME-RESERVED", "path_substring": "marketplace.json" } ]' '["MARKETPLACE-NAME-FORMAT"]' false "scan-graph.sh emits [MARKETPLACE-NAME-RESERVED] for an official marketplace name; a marketplace-only root (no plugin.json) is audited too"
mk marketplace-name-spelling "claude.code.plugins" ''
ev 186-marketplace-name-spelling marketplace-name-spelling '[ { "tag": "MARKETPLACE-NAME-RESERVED", "path_substring": "marketplace.json" } ]' '["MARKETPLACE-NAME-FORMAT"]' false "scan-graph.sh emits [MARKETPLACE-NAME-RESERVED]: claude.code.plugins is another spelling of claude-code-plugins"
mk marketplace-name-format "my marketplace" ''
ev 187-marketplace-name-format marketplace-name-format '[ { "tag": "MARKETPLACE-NAME-FORMAT", "path_substring": "marketplace.json" } ]' '["MARKETPLACE-NAME-RESERVED"]' false "scan-graph.sh emits [MARKETPLACE-NAME-FORMAT] for a marketplace name containing a space"
mk marketplace-entry-names "acme-tools" '{ "name": "anthropic-helper", "source": "./" }, { "name": "ship@it", "source": "./" }'
ev 188-marketplace-entry-names marketplace-entry-names '[ { "tag": "PLUGIN-RESERVED-NAME", "path_substring": "marketplace.json" }, { "tag": "PLUGIN-NAME-FORMAT", "path_substring": "marketplace.json" } ]' '["MARKETPLACE-NAME-RESERVED","MARKETPLACE-NAME-FORMAT"]' false "scan-graph.sh applies the plugin-name rules to each marketplace entry: anthropic-helper is reserved, ship@it is malformed"
mk marketplace-inline-reserved "Inline" ''
ev 189-marketplace-inline-reserved marketplace-inline-reserved '[ { "tag": "MARKETPLACE-NAME-RESERVED", "path_substring": "marketplace.json" } ]' '[]' false "scan-graph.sh emits [MARKETPLACE-NAME-RESERVED]: inline (any casing) is the name Claude Code gives --plugin-dir plugins"
# ---- L8
sk() { w "$F/$1/dot-claude/skills/$2/SKILL.md" <<EOF
---
name: $2
description: $3
$4---
Body.
EOF
}
mkplug() { printf '{ "name": "%s", "version": "1.0.0", "description": "fixture"%s }\n' "$2" "$3" | w "$F/$1/dot-claude/.claude-plugin/plugin.json"; }
G='graders'
# 190: a case with no grader
mkplug eval-case-no-grader eval-demo ''
sk eval-case-no-grader triage "Triage incoming bug reports." ""
printf 'Triage this bug: the login button is dead.\n' | w $F/eval-case-no-grader/dot-claude/evals/ungraded/prompt.md
printf 'Triage this bug: the login button is dead.\n' | w $F/eval-case-no-grader/dot-claude/evals/graded/prompt.md
printf -- '---\ntype: tool_used\ntool: Skill\ninput_match: '"'"'"skill"\\s*:\\s*"(?:[\\w-]+:)?triage"'"'"'\n---\n' | w $F/eval-case-no-grader/dot-claude/evals/graded/graders/skill-fired.md
ev 190-eval-case-no-grader eval-case-no-grader '[ { "tag": "EVAL-CASE-NO-GRADER", "path_substring": "evals/ungraded" } ]' '["EVAL-NO-SKILL-GRADER","PLUGIN-NO-EVALS"]' false "scan-graph.sh emits [EVAL-CASE-NO-GRADER] for evals/ungraded (prompt.md, no graders/ and no case.yaml); the sibling case with graders/skill-fired.md is fine and names the triage skill"
# 191: suite exists but no tool_used Skill grader names the skill
mkplug eval-no-skill-grader eval-demo ''
sk eval-no-skill-grader triage "Triage incoming bug reports." ""
printf 'Triage this bug.\n' | w $F/eval-no-skill-grader/dot-claude/evals/triage-case/prompt.md
printf -- '---\ntype: llm\n---\nPASS when the reply classifies the bug.\n' | w $F/eval-no-skill-grader/dot-claude/evals/triage-case/graders/criteria.md
ev 191-eval-no-skill-grader eval-no-skill-grader '[ { "tag": "EVAL-NO-SKILL-GRADER", "path_substring": "skills/triage" } ]' '["EVAL-CASE-NO-GRADER","PLUGIN-NO-EVALS"]' false "scan-graph.sh emits [EVAL-NO-SKILL-GRADER]: the only grader is type llm, so nothing checks that Claude chooses the triage skill"
# 192: clean — skill graded through case.yaml, disabled skill exempt, results/ and mocks/ ignored
mkplug eval-suite-clean eval-demo ''
sk eval-suite-clean triage "Triage incoming bug reports." ""
sk eval-suite-clean deploy "Ship a release." $'disable-model-invocation: true\n'
printf 'Triage this bug.\n' | w $F/eval-suite-clean/dot-claude/evals/triage-case/prompt.md
w $F/eval-suite-clean/dot-claude/evals/triage-case/case.yaml <<'EOF'
schema_version: "1.1"
name: triage-case
graders:
  - name: skill-fired
    type: tool_used
    tool: Skill
    input_match: '"skill"\s*:\s*"(?:[\w-]+:)?triage"'
EOF
echo '{}' | w $F/eval-suite-clean/dot-claude/evals/results/2026-10-01T00-00-00/aggregate-result.json
printf 'mocked tool result\n' | w $F/eval-suite-clean/dot-claude/evals/mocks/server/tool.md
ev 192-eval-suite-clean eval-suite-clean '[]' '["EVAL-CASE-NO-GRADER","EVAL-NO-SKILL-GRADER","PLUGIN-NO-EVALS"]' true "scan-graph.sh stays silent: the case grades through a graders: list in case.yaml that names triage; deploy sets disable-model-invocation so needs no trigger grader; results/ and mocks/ are not cases"
# 193: skill, no suite (evals/ holds another tool's JSON)
mkplug plugin-no-evals eval-demo ''
sk plugin-no-evals triage "Triage incoming bug reports." ""
echo '{ "id": "other-tool-case" }' | w $F/plugin-no-evals/dot-claude/evals/other-tool-case.json
ev 193-plugin-no-evals plugin-no-evals '[ { "tag": "PLUGIN-NO-EVALS", "path_substring": "plugin.json" } ]' '["EVAL-CASE-NO-GRADER","EVAL-NO-SKILL-GRADER"]' false "scan-graph.sh emits [PLUGIN-NO-EVALS]: the plugin ships a model-invocable skill and evals/ holds only another tool's JSON, no <case>/prompt.md or case.yaml"
# 194: experimental.evals redirects the eval dir
mkplug eval-dir-experimental eval-demo ', "experimental": { "evals": "./quality/evals" }'
sk eval-dir-experimental triage "Triage incoming bug reports." ""
printf 'Triage this bug.\n' | w $F/eval-dir-experimental/dot-claude/quality/evals/ungraded/prompt.md
ev 194-eval-dir-experimental eval-dir-experimental '[ { "tag": "EVAL-CASE-NO-GRADER", "path_substring": "quality/evals/ungraded" } ]' '["PLUGIN-NO-EVALS"]' false "scan-graph.sh follows experimental.evals (quality/evals) instead of evals/, so the ungraded case there is found and PLUGIN-NO-EVALS is not raised"
```
