#!/usr/bin/env bash
# test_history.sh — deterministic tests for scan-history.sh aggregation.
#
# scan-history.sh emits an AGGREGATE JSON (history-scan.json), not [TAG] lines,
# so it can't go through the tag-set harness in test_scripts.sh. Instead, for
# every evals/*.json with fixture.kind == "synthetic-jsonl" and grader.method
# == "code":
#   1. Copy the fixture's .claude/ (+ optional sibling .claude.json) into a temp
#      $HOME, then substitute the timestamp placeholders so the planted events
#      land inside (__TS_RECENT__) or outside (__TS_OLD__) the scan window.
#   2. Run scan-history.sh --no-cache against that $HOME.
#   3. Assert each success_criteria.history_assertions[] {jq, equals} against the
#      produced history-scan.json (a jq path == an expected scalar / null).
#
# No network / API key — safe for CI. Requires jq + GNU date.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

EVALS="$REPO/commands/claude-markdown-health-check/evals"
HISTORY="$REPO/commands/scripts/scan-history.sh"

command -v jq >/dev/null 2>&1 || { echo "test_history.sh: jq is required" >&2; exit 2; }
[ -d "$EVALS" ] || { echo "test_history.sh: no evals dir at $EVALS" >&2; exit 2; }

filter="${1:-}"
TS_RECENT="$(date -u -d "2 days ago" +"%Y-%m-%dT%H:%M:%SZ")"
TS_OLD="$(date -u -d "60 days ago" +"%Y-%m-%dT%H:%M:%SZ")"

for f in "$EVALS"/*.json; do
    [ -e "$f" ] || continue
    kind=$(jq -r '.fixture.kind // ""' "$f")
    [ "$kind" = "synthetic-jsonl" ] || continue
    method=$(jq -r '.grader.method // "code"' "$f")
    [ "$method" = "code" ] || continue
    id=$(jq -r '.id' "$f")
    [ -n "$filter" ] && [[ "$id" != "$filter"* ]] && continue

    dir=$(jq -r '.fixture.dir' "$f")
    echo "=== $id ($dir) ==="

    tmp=$(mktemp -d)
    home="$tmp/home"; cache="$tmp/cache"
    mkdir -p "$home/.claude" "$cache"
    cp -r "$REPO/$dir/.claude/." "$home/.claude/"
    [ -f "$REPO/$dir/.claude.json" ] && cp "$REPO/$dir/.claude.json" "$home/.claude.json"

    while IFS= read -r jf; do
        sed -i -e "s/__TS_RECENT__/$TS_RECENT/g" -e "s/__TS_OLD__/$TS_OLD/g" "$jf"
    done < <(find "$home/.claude/projects" -name '*.jsonl' 2>/dev/null || true)

    out="$cache/history-scan.json"
    env "HOME=$home" "CLAUDE_PLUGIN_DATA=$cache" bash "$HISTORY" --no-cache >/dev/null 2>&1 || true

    if [ ! -f "$out" ]; then
        no "$id: scan-history.sh produced no history-scan.json"
        rm -rf "$tmp"; continue
    fi

    while IFS=$'\t' read -r jqexpr expected; do
        [ -z "$jqexpr" ] && continue
        actual=$(jq -r "$jqexpr" "$out" 2>/dev/null)
        if [ "$actual" = "$expected" ]; then
            ok "$id: $jqexpr == $expected"
        else
            no "$id: $jqexpr => '$actual' (expected '$expected')"
        fi
    done < <(jq -r '.success_criteria.history_assertions[]? | [.jq, (.equals|tostring)] | @tsv' "$f")

    rm -rf "$tmp"
done

echo
echo "history: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
