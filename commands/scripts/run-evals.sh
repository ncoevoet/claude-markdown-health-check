#!/usr/bin/env bash
# run-evals.sh — manual eval runner for the LLM-graded judgment cases.
#
# A dependency-light alternative to run-evals-headless.sh (no `claude` subprocess).
# For each evals/*.json with grader.method == "llm-rubric":
#   1. Print the case id + its expected (and not-expected) behaviours.
#   2. Ask you to run /claude-markdown-health-check against the named fixture in
#      Claude Code, save the report, and paste its path.
#   3. Grep the report for each expected_behavior needle; mark PASS/FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
EVALS="$REPO/commands/claude-markdown-health-check/evals"
filter="${1:-}"
command -v jq >/dev/null 2>&1 || { echo "run-evals: jq is required." >&2; exit 2; }

fail=0
for f in "$EVALS"/*.json; do
    [ -e "$f" ] || continue
    id=$(jq -r '.id' "$f")
    [ "$(jq -r '.grader.method' "$f")" = "llm-rubric" ] || continue
    [ -n "$filter" ] && [[ "$id" != "$filter"* ]] && continue

    echo; echo "=== eval: $id ==="
    echo "Fixture: $(jq -r '.fixture.dir' "$f")/.claude"
    echo "Expected behaviour:"; jq -r '.expected_behavior[]? | "  + " + .' "$f"
    echo "Expected NOT behaviour:"; jq -r '.expected_not_behavior[]? | "  - " + .' "$f"
    echo
    read -r -p "Path to the saved /claude-markdown-health-check report (blank to skip): " report
    [ -z "$report" ] && { echo "SKIPPED"; continue; }
    [ ! -f "$report" ] && { echo "FAIL: report not found at $report"; fail=$((fail + 1)); continue; }

    miss=0
    while IFS= read -r line; do
        needle=$(echo "$line" | awk '{print $1, $2, $3}')
        if ! grep -q -i -F "$needle" "$report"; then
            echo "  missing: $line"; miss=$((miss + 1))
        fi
    done < <(jq -r '.expected_behavior[]?' "$f")

    if [ "$miss" -eq 0 ]; then echo "PASS"; else echo "FAIL ($miss expected behaviours not found)"; fail=$((fail + 1)); fi
done

echo
[ "$fail" -eq 0 ] && echo "all manual evals passed" || echo "$fail eval(s) failed"
[ "$fail" -eq 0 ]
