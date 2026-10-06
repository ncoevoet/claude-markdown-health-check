#!/usr/bin/env bash
# test_scripts.sh — data-driven deterministic test suite.
#
# For every evals/*.json whose grader.method == "code":
#   1. Run the declared scanners (validate-skills / scan-graph) against the
#      fixture's config tree, materialized into a temp dir literally named
#      .claude (HOME-overridden when the case needs user-tree gating). On disk
#      fixtures store it as dot-claude/ so Claude Code's lazy nested-skills
#      discovery never registers a fixture SKILL.md as a live skill in this
#      repo.
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
    git_init=$(jq -r '.fixture.git_init // false' "$f")
    scan_subdir=$(jq -r '.fixture.scan_subdir // ""' "$f")
    home_project_tree=$(jq -r '.fixture.home_project_tree // false' "$f")
    mapfile -t scanners < <(jq -r '.fixture.scanners[]?' "$f")
    expect_clean=$(jq -r '.success_criteria.expect_clean // false' "$f")

    echo "=== $id ($dir) ==="

    tmp=$(mktemp -d)
    cache="$tmp/cache"; mkdir -p "$cache"
    # Fixtures store their config tree on disk as dot-claude/ (not .claude/) so
    # Claude Code's lazy nested-skills discovery never registers a fixture's
    # deliberately-bad SKILL.md as a live skill while this repo is open. Every
    # case — home-overridden or not — materializes the WHOLE fixture (dot-claude/
    # renamed to .claude/, plus any root-level sibling such as .mcp.json that a
    # scanner resolves via CLAUDE_DIR/../…) into a temp copy before scanning, so
    # no scanner behavior depends on the on-disk rename.
    mkdir -p "$tmp/target"
    cp -r "$REPO/$dir/." "$tmp/target/"
    mv "$tmp/target/dot-claude" "$tmp/target/.claude"
    if [ "$needs_home" = "true" ]; then
        mkdir -p "$tmp/home"
        if [ "$home_project_tree" = "true" ]; then
            # home_project_tree: dot-claude/ is a PROJECT tree scanned in place at
            # $tmp/target/.claude (repo marker planted so ancestor walks stop there);
            # home/ holds the fake HOME's contents (home/dot-claude/ -> ~/.claude,
            # home/dot-claude.json -> ~/.claude.json, home/dot-claudeignore -> ~/.claudeignore).
            mkdir -p "$tmp/target/.git"
            cp -r "$tmp/target/home/." "$tmp/home/"
            rm -rf "$tmp/target/home"
            mv "$tmp/home/dot-claude" "$tmp/home/.claude"
            [ -f "$tmp/home/dot-claude.json" ] && mv "$tmp/home/dot-claude.json" "$tmp/home/.claude.json"
            [ -f "$tmp/home/dot-claudeignore" ] && mv "$tmp/home/dot-claudeignore" "$tmp/home/.claudeignore"
        else
            mv "$tmp/target/.claude" "$tmp/home/.claude"
        fi
        # installed_plugins.json carries absolute installPaths, which a fixture cannot
        # know ahead of the temp copy. Fixtures write the literal token __HOME__ and we
        # expand it here so a case can point at a real directory inside the fake HOME.
        [ -f "$tmp/home/.claude/plugins/installed_plugins.json" ] &&
            sed -i "s|__HOME__|$tmp/home|g" "$tmp/home/.claude/plugins/installed_plugins.json"
        # Opt-in home siblings: dot-claude.json -> ~/.claude.json, dot-claudeignore -> ~/.claudeignore.
        [ -f "$tmp/target/dot-claude.json" ] && mv "$tmp/target/dot-claude.json" "$tmp/home/.claude.json"
        [ -f "$tmp/target/dot-claudeignore" ] && mv "$tmp/target/dot-claudeignore" "$tmp/home/.claudeignore"
        target="$tmp/home/.claude"
        [ "$home_project_tree" = "true" ] && target="$tmp/target/.claude"
        run_env=(env "HOME=$tmp/home" "CLAUDE_PLUGIN_DATA=$cache")
    else
        # check_local_md_tracked (validate-skills.sh) walks up from CLAUDE_DIR
        # looking for a .git dir to decide whether an ungitignored CLAUDE.local.md
        # is worth flagging. Fixtures used to be scanned in place inside this
        # repo's own git tree, so plant a marker here to keep that check exercised
        # the same way now that the scan runs against a temp copy instead.
        if [ "$git_init" = "true" ]; then
            # Opt-in real repo (index only, no commit): rev-parse / ls-files work.
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$tmp/target" init -q
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$tmp/target" "add" -A
        else
            mkdir -p "$tmp/target/.git"
        fi
        target="$tmp/target/.claude"
        if [ -n "$scan_subdir" ]; then
            # Opt-in nested scan: .claude lives under <rel>; the repo root stays at $tmp/target.
            mkdir -p "$tmp/target/$scan_subdir"
            mv "$tmp/target/.claude" "$tmp/target/$scan_subdir/.claude"
            target="$tmp/target/$scan_subdir/.claude"
        fi
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

# Materialize into a temp dir literally named .claude — same reason as the
# per-case loop above.
tmp_lc=$(mktemp -d)
mkdir -p "$tmp_lc/clean/.claude" "$tmp_lc/grounded/.claude"
cp -r "$REPO/tests/fixtures/clean/dot-claude/." "$tmp_lc/clean/.claude/"
cp -r "$REPO/tests/fixtures/grounded-claudemd/dot-claude/." "$tmp_lc/grounded/.claude/"

# --listing-cost excludes disable-model-invocation skills: the clean fixture's
# only skill (welltuned) sets the flag, so total and count must both be 0.
lc=$(bash "$VALIDATE" --listing-cost "$tmp_lc/clean/.claude" | awk '{print $1, $2}')
if [ "$lc" = "0 0" ]; then
    ok "listing-cost: disable-model-invocation skill excluded"
else
    no "listing-cost: expected '0 0' for clean fixture, got '$lc'"
fi

# The counting path must still work: grounded-claudemd's single skill sets no
# disable-model-invocation, so it has to contribute a non-zero cost. Without this,
# the assertion above would pass even if compute_listing_cost always returned 0.
read -r lc_total lc_count _ < <(bash "$VALIDATE" --listing-cost "$tmp_lc/grounded/.claude")
if [ "$lc_count" = "1" ] && [ "$lc_total" -gt 0 ]; then
    ok "listing-cost: model-invocable skill still counted ($lc_total chars)"
else
    no "listing-cost: expected 1 entry with non-zero chars, got '$lc_total $lc_count'"
fi
rm -rf "$tmp_lc"

echo
echo "deterministic: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
