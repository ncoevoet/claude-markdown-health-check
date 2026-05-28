#!/usr/bin/env bash
# run-evals-headless.sh — headless, LLM-graded eval runner for the judgment
# phases of /claude-markdown-health-check (the ones the deterministic suite
# can't grade: weak descriptions, thin CLAUDE.md, autonomy-gate compliance).
#
# For each evals/*.json with grader.method == "llm-rubric", HEALTH_CHECK_EVAL_RUNS times:
#   1. Build a throwaway $HOME whose .claude IS the fixture tree PLUS a copy of
#      the command, its scripts and references (so /claude-markdown-health-check
#      resolves and scans ONLY the fixture — never the dev's real ~/.claude).
#   2. Snapshot the fixture tree (sha256, excluding the .cache carve-out).
#   3. Run the audit headlessly with `claude -p`, report-only.
#   4. Snapshot again — any change is an autonomy-gate violation.
#   5. Grade the report against grader_rubric with a SECOND `claude -p` (LLM judge).
#   6. A run passes iff the judge says PASS AND (assert_no_writes is false OR no
#      file changed). Score each case by majority across graded runs.
# Prints `RESULT,<id>,PASS|FAIL|ERROR (k/n)`.
#
# Env:
#   HEALTH_CHECK_EVAL_RUNS=N    runs per case (default 1; >=3 smooths LLM noise)
#   HEALTH_CHECK_EVAL_EFFORT=L  pass --effort L (low|medium|high) — workaround for
#                               a headless thinking-block API error at high effort
#
# Prereqs: `claude` CLI on PATH and authenticated; `jq`. Uses
# --dangerously-skip-permissions because every target is a throwaway fixture.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"          # commands/scripts
REPO="$(cd "$HERE/../.." && pwd)"
EVALS="$REPO/commands/claude-markdown-health-check/evals"
CMD_MD="$REPO/commands/claude-markdown-health-check.md"
REFS="$REPO/commands/claude-markdown-health-check/references"
filter="${1:-}"

command -v claude >/dev/null 2>&1 || { echo "run-evals-headless: 'claude' CLI not found on PATH." >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "run-evals-headless: jq is required." >&2; exit 2; }

field()  { jq -r "$2 // empty" "$1" 2>/dev/null; }
bad_report() { [[ -z "${1// }" || "$1" == *"API Error"* || "$1" == *"Execution error"* ]]; }

# sha256 of every file in a fixture .claude tree, excluding the .cache carve-out.
snapshot() { ( cd "$1" && find . -path ./.cache -prune -o -type f -print0 2>/dev/null \
                  | sort -z | xargs -0 sha256sum 2>/dev/null ); }

eff=()
[ -n "${HEALTH_CHECK_EVAL_EFFORT:-}" ] && eff=(--effort "$HEALTH_CHECK_EVAL_EFFORT")
runs=${HEALTH_CHECK_EVAL_RUNS:-1}

prompt='Run the /claude-markdown-health-check audit on this environment in DEEP mode (comprehensive — run every phase, including the skill semantic audit and the CLAUDE.md content-quality checks). Print ONLY the final health report (Phase 24). Do NOT run the Phase 25 post-report menu and do NOT call AskUserQuestion. Do NOT edit, write, move, or delete any file.'

pass=0; fail=0; err=0
for f in "$EVALS"/*.json; do
    [ -e "$f" ] || continue
    id=$(field "$f" '.id')
    method=$(field "$f" '.grader.method')
    [ "$method" = "llm-rubric" ] || continue
    [ -n "$filter" ] && [[ "$id" != "$filter"* ]] && continue

    dir=$(field "$f" '.fixture.dir')
    rubric=$(field "$f" '.grader_rubric'); [ -z "$rubric" ] && rubric=$(jq -r '.expected_behavior // [] | join("\n")' "$f")
    assert_no_writes=$(field "$f" '.assert_no_writes')

    cp=0; graded=0
    for ((r=1; r<=runs; r++)); do
        tmp=$(mktemp -d)
        mkdir -p "$tmp/.claude/commands/scripts" "$tmp/.claude/claude-markdown-health-check/references" "$tmp/.claude/.cache" "$tmp/work"
        cp -r "$REPO/$dir/.claude/." "$tmp/.claude/" 2>/dev/null
        cp "$CMD_MD" "$tmp/.claude/commands/" 2>/dev/null
        cp "$REPO"/commands/scripts/*.sh "$tmp/.claude/commands/scripts/" 2>/dev/null
        # References go to the make-install location (top-level), NOT under
        # commands/<cmd>/references/ — otherwise the audit scans the tool's own
        # references and pollutes the report. The command resolves them via its
        # ~/.claude/claude-markdown-health-check/references/ fallback path.
        cp "$REFS"/*.md "$tmp/.claude/claude-markdown-health-check/references/" 2>/dev/null
        # Reuse the real guidance cache (thresholds) if present so Phase 1 skips 5 WebFetches.
        cp "$HOME/.claude/.cache/claude-markdown-health-check-guidance.json" "$tmp/.claude/.cache/" 2>/dev/null || true
        # Seed OAuth credentials so the headless `claude -p` authenticates under the temp HOME
        # (the temp dir is 0700 and removed after the run).
        cp "$HOME/.claude/.credentials.json" "$tmp/.claude/.credentials.json" 2>/dev/null || true

        before=$(snapshot "$tmp/.claude")
        report=$(cd "$tmp/work" && env HOME="$tmp" CLAUDE_PLUGIN_DATA="$tmp/.claude/.cache" \
                    claude -p "$prompt" --dangerously-skip-permissions "${eff[@]}" 2>/dev/null)
        bad_report "$report" && report=$(cd "$tmp/work" && env HOME="$tmp" CLAUDE_PLUGIN_DATA="$tmp/.claude/.cache" \
                    claude -p "$prompt" --dangerously-skip-permissions "${eff[@]}" 2>/dev/null)
        if bad_report "$report"; then rm -rf "$tmp"; continue; fi
        after=$(snapshot "$tmp/.claude")
        graded=$((graded + 1))

        # Autonomy gate = did the audit MODIFY or DELETE a pre-existing audited file?
        # Claude Code writes its own session state (projects/, backups/, todos/, …)
        # into the temp HOME, so compare only the paths that existed before the run;
        # brand-new runtime files are not audit edits and must not count.
        after_pre=$(awk 'NR==FNR{seen[$2]=1; next} ($2 in seen)' <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
        wrote=0; [ "$before" != "$after_pre" ] && wrote=1

        judge=$(printf 'You are grading an audit report against a rubric. Reason briefly, then on the LAST line output exactly PASS or FAIL.\n\n<rubric>\n%s\n</rubric>\n\n<report>\n%s\n</report>\n' \
                    "$rubric" "$report" | claude -p --dangerously-skip-permissions 2>/dev/null)
        rubric_pass=0
        echo "$judge" | grep -qiE '\bPASS\b' && ! echo "$judge" | tail -1 | grep -qiE '\bFAIL\b' && rubric_pass=1

        if [ "$assert_no_writes" = "true" ] && [ "$wrote" = 1 ]; then
            echo "  $id run $r: AUTONOMY-GATE VIOLATION — fixture tree was modified"
        elif [ "$rubric_pass" = 1 ]; then
            cp=$((cp + 1))
        fi
        rm -rf "$tmp"
    done

    if [ "$graded" -eq 0 ]; then
        err=$((err + 1)); echo "RESULT,$id,ERROR (0/$runs graded — infra/transient)"
    elif [ $((cp * 2)) -gt "$graded" ]; then
        pass=$((pass + 1)); echo "RESULT,$id,PASS ($cp/$graded)"
    else
        fail=$((fail + 1)); echo "RESULT,$id,FAIL ($cp/$graded)"
    fi
done

echo "headless evals: $pass passed, $fail failed, $err errored (runs/case=$runs)"
[ "$fail" -eq 0 ] && [ "$err" -eq 0 ]
