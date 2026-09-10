#!/usr/bin/env bash
# test_history.sh — deterministic tests for scan-history.sh aggregation.
#
# scan-history.sh emits an AGGREGATE JSON (history-scan.json), not [TAG] lines,
# so it can't go through the tag-set harness in test_scripts.sh. Instead, for
# every evals/*.json with fixture.kind == "synthetic-jsonl" and grader.method
# == "code":
#   1. Copy the fixture's dot-claude/ (+ optional sibling dot-claude.json) into
#      a temp $HOME as .claude/ (+ .claude.json) — on disk fixtures use the
#      dot-claude name so Claude Code's lazy nested-skills discovery never
#      registers a fixture SKILL.md as a live skill in this repo — then
#      substitute the timestamp placeholders so the planted events land inside
#      (__TS_RECENT__, __TS_RECENT_PLUS10__, __TS_RECENT_SEC__) or outside
#      (__TS_OLD__) the scan window. __TS_RECENT__/__TS_RECENT_PLUS10__/
#      __TS_OLD__ carry REAL Claude Code millisecond precision
#      ("...SS.mmmZ") — that shape is what production transcripts actually
#      emit, and is the shape that used to defeat scan-history.sh's
#      fromdateiso8601-based epoch_of entirely (see scan-history.sh:99-121).
#      __TS_RECENT_SEC__ is kept at whole-second precision ("...SSZ") so the
#      suite still exercises the other parse path (no fractional part to
#      strip). __TS_RECENT_PLUS10__ is __TS_RECENT__ + 10 real seconds, for
#      fixtures that need a genuine, non-zero prompt-to-fire gap.
#   2. Run scan-history.sh --no-cache against that $HOME, passing
#      --anchors-file when the case sets fixture.anchors_file (a path, relative
#      to the repo root) or fixture.anchors (an inline {"skill":["token"]}
#      object, written to a temp file first) -- otherwise the scanner runs
#      with no anchors table and observedRecall stays empty.
#   3. Assert each success_criteria.history_assertions[] {jq, equals} against the
#      produced history-scan.json (a jq path == an expected scalar / null).
#
# No network / API key — safe for CI. Requires jq + GNU date.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

EVALS="$REPO/evals"
HISTORY="$REPO/plugin/commands/scripts/scan-history.sh"

command -v jq >/dev/null 2>&1 || { echo "test_history.sh: jq is required" >&2; exit 2; }
[ -d "$EVALS" ] || { echo "test_history.sh: no evals dir at $EVALS" >&2; exit 2; }

filter="${1:-}"
TS_RECENT_EPOCH="$(date -u -d "2 days ago" +%s)"
TS_OLD_EPOCH="$(date -u -d "60 days ago" +%s)"
# Millisecond precision (".123Z" / ".789Z") to match real Claude Code
# transcripts. TS_RECENT_SEC is the one deliberately-kept whole-second case.
TS_RECENT="$(date -u -d "@$TS_RECENT_EPOCH" +"%Y-%m-%dT%H:%M:%S.123Z")"
TS_RECENT_PLUS10="$(date -u -d "@$((TS_RECENT_EPOCH + 10))" +"%Y-%m-%dT%H:%M:%S.456Z")"
TS_RECENT_SEC="$(date -u -d "@$TS_RECENT_EPOCH" +"%Y-%m-%dT%H:%M:%SZ")"
TS_OLD="$(date -u -d "@$TS_OLD_EPOCH" +"%Y-%m-%dT%H:%M:%S.789Z")"

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
    # Fixtures store their config tree on disk as dot-claude/ (+ sibling
    # dot-claude.json) so Claude Code's lazy nested-skills discovery never
    # registers a fixture's SKILL.md as a live skill while this repo is open.
    # Materialize into a temp dir literally named .claude before scanning.
    cp -r "$REPO/$dir/dot-claude/." "$home/.claude/"
    [ -f "$REPO/$dir/dot-claude.json" ] && cp "$REPO/$dir/dot-claude.json" "$home/.claude.json"

    while IFS= read -r jf; do
        sed -i \
            -e "s/__TS_RECENT_PLUS10__/$TS_RECENT_PLUS10/g" \
            -e "s/__TS_RECENT_SEC__/$TS_RECENT_SEC/g" \
            -e "s/__TS_RECENT__/$TS_RECENT/g" \
            -e "s/__TS_OLD__/$TS_OLD/g" \
            "$jf"
    done < <(find "$home/.claude/projects" -name '*.jsonl' 2>/dev/null || true)

    anchors_args=()
    anchors_file_rel=$(jq -r '.fixture.anchors_file // empty' "$f")
    if [ -n "$anchors_file_rel" ]; then
        anchors_args=(--anchors-file "$REPO/$anchors_file_rel")
    elif jq -e '.fixture.anchors | type == "object"' "$f" >/dev/null 2>&1; then
        anchors_tmp="$tmp/anchors.json"
        jq -c '.fixture.anchors' "$f" >"$anchors_tmp"
        anchors_args=(--anchors-file "$anchors_tmp")
    fi

    out="$cache/history-scan.json"
    env "HOME=$home" "CLAUDE_PLUGIN_DATA=$cache" bash "$HISTORY" --no-cache "${anchors_args[@]}" >/dev/null 2>&1 || true

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
