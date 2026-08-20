#!/usr/bin/env bash
# test_scripts.sh — data-driven deterministic test suite.
#
# For every evals/*.json whose grader.method == "code":
#   1. Run the declared scanners (validate-skills / scan-graph) against the
#      fixture .claude tree (HOME-overridden into a temp dir when the case needs
#      user-tree gating).
#   2. Collect the emitted TAG set + normalized finding lines.
#   3. Assert: expect_clean -> empty set; each must_detect.tag present (and, when
#      given, at the must_detect.path_substring); each must_not_flag absent.
#
# No network / API key — safe for CI. Requires jq.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

EVALS="$REPO/evals"
VALIDATE="$REPO/plugin/commands/scripts/validate-skills.sh"
GRAPH="$REPO/plugin/commands/scripts/scan-graph.sh"

command -v jq >/dev/null 2>&1 || { echo "test_scripts.sh: jq is required" >&2; exit 2; }
[ -d "$EVALS" ] || { echo "test_scripts.sh: no evals dir at $EVALS" >&2; exit 2; }

filter="${1:-}"

for f in "$EVALS"/*.json; do
    [ -e "$f" ] || continue
    id=$(jq -r '.id' "$f")
    method=$(jq -r '.grader.method // "code"' "$f")
    [ "$method" = "code" ] || continue
    # synthetic-jsonl cases assert on history-scan.json, not on a tag set — they
    # are owned by tests/test_history.sh, not this tag-based runner.
    [ "$(jq -r '.fixture.kind // "claude-tree"' "$f")" = "synthetic-jsonl" ] && continue
    [ -n "$filter" ] && [[ "$id" != "$filter"* ]] && continue

    dir=$(jq -r '.fixture.dir' "$f")
    needs_home=$(jq -r '.fixture.needs_home_override // false' "$f")
    mapfile -t scanners < <(jq -r '.fixture.scanners[]?' "$f")
    expect_clean=$(jq -r '.success_criteria.expect_clean // false' "$f")

    echo "=== $id ($dir) ==="

    tmp=$(mktemp -d)
    cache="$tmp/cache"; mkdir -p "$cache"
    if [ "$needs_home" = "true" ]; then
        mkdir -p "$tmp/home/.claude"
        cp -r "$REPO/$dir/.claude/." "$tmp/home/.claude/"
        # installed_plugins.json carries absolute installPaths, which a fixture cannot
        # know ahead of the temp copy. Fixtures write the literal token __HOME__ and we
        # expand it here so a case can point at a real directory inside the fake HOME.
        [ -f "$tmp/home/.claude/plugins/installed_plugins.json" ] &&
            sed -i "s|__HOME__|$tmp/home|g" "$tmp/home/.claude/plugins/installed_plugins.json"
        target="$tmp/home/.claude"
        run_env=(env "HOME=$tmp/home" "CLAUDE_PLUGIN_DATA=$cache")
    else
        target="$REPO/$dir/.claude"
        run_env=(env "CLAUDE_PLUGIN_DATA=$cache")
    fi

    tags=""; findings=""
    for s in "${scanners[@]}"; do
        case "$s" in
            validate-skills)
                out=$("${run_env[@]}" bash "$VALIDATE" "$target" 2>&1 || true)
                assert_validator_completed "$out" "$id: validate-skills ran to completion"
                tags+=$'\n'$(printf '%s' "$out" | extract_validator_tags)
                findings+=$'\n'$(printf '%s' "$out" | normalize_validator_findings)
                ;;
            scan-graph)
                out=$("${run_env[@]}" bash "$GRAPH" --no-cache "$target" 2>/dev/null || true)
                tags+=$'\n'$(printf '%s' "$out" | extract_graph_tags)
                findings+=$'\n'$(printf '%s' "$out" | normalize_graph_findings)
                ;;
            *) echo "  (unknown scanner '$s' — skipped)";;
        esac
    done
    tags=$(printf '%s\n' "$tags" | grep -E '^[A-Z0-9-]+$' | sort -u || true)

    if [ "$expect_clean" = "true" ]; then
        assert_empty_tagset "$tags" "$id: clean tree -> zero findings"
    fi

    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        assert_tag_present "$tags" "$tag" "$id: detects $tag"
    done < <(jq -r '.success_criteria.must_detect[]?.tag' "$f")

    # locator checks (only entries carrying path_substring)
    while IFS=$'\t' read -r tag sub; do
        [ -z "$tag" ] && continue
        assert_finding_at "$findings" "$tag" "$sub" "$id: $tag at $sub"
    done < <(jq -r '.success_criteria.must_detect[]? | select(.path_substring != null) | [.tag, .path_substring] | @tsv' "$f")

    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        assert_tag_absent "$tags" "$tag" "$id: no false positive $tag"
    done < <(jq -r '.success_criteria.must_not_flag[]?' "$f")

    rm -rf "$tmp"
done

# --listing-cost excludes disable-model-invocation skills: the clean fixture's
# only skill (welltuned) sets the flag, so total and count must both be 0.
lc=$(bash "$VALIDATE" --listing-cost "$REPO/tests/fixtures/clean/.claude" | awk '{print $1, $2}')
if [ "$lc" = "0 0" ]; then
    ok "listing-cost: disable-model-invocation skill excluded"
else
    no "listing-cost: expected '0 0' for clean fixture, got '$lc'"
fi

# The counting path must still work: grounded-claudemd's single skill sets no
# disable-model-invocation, so it has to contribute a non-zero cost. Without this,
# the assertion above would pass even if compute_listing_cost always returned 0.
read -r lc_total lc_count _ < <(bash "$VALIDATE" --listing-cost "$REPO/tests/fixtures/grounded-claudemd/.claude")
if [ "$lc_count" = "1" ] && [ "$lc_total" -gt 0 ]; then
    ok "listing-cost: model-invocable skill still counted ($lc_total chars)"
else
    no "listing-cost: expected 1 entry with non-zero chars, got '$lc_total $lc_count'"
fi

echo
echo "deterministic: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
