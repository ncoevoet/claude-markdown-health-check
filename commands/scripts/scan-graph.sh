#!/usr/bin/env bash
# scan-graph.sh — Static graph scanner for plugin integrity, reference graph,
# and auto-memory hygiene. Produces a single JSON cache file consumed by
# phases 2, 11, and 20 of the audit.
#
# Usage: scan-graph.sh [--no-cache] [--refresh] [CLAUDE_DIR]
#
# CLAUDE_DIR defaults to $HOME/.claude. Plugin and memory checks only run
# when CLAUDE_DIR resolves to the user tree; ref-graph runs on any tree.
# Cache file: ${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/graph-scan.json
# TTL: 1h (override via SCAN_GRAPH_TTL).

set -uo pipefail

NO_CACHE=0; REFRESH=0; POS_ARGS=()
for a in "$@"; do
    case "$a" in
        --no-cache) NO_CACHE=1 ;;
        --refresh)  REFRESH=1 ;;
        *) POS_ARGS+=("$a") ;;
    esac
done
CLAUDE_DIR="${POS_ARGS[0]:-$HOME/.claude}"
USER_TREE="$HOME/.claude"
IS_USER_TREE=0
if command -v readlink >/dev/null 2>&1; then
    [ "$(readlink -f "$CLAUDE_DIR" 2>/dev/null)" = "$(readlink -f "$USER_TREE" 2>/dev/null)" ] && IS_USER_TREE=1
else
    [ "$CLAUDE_DIR" = "$USER_TREE" ] && IS_USER_TREE=1
fi
SCOPE="project"
[ "$IS_USER_TREE" = 1 ] && SCOPE="user"

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}"
CACHE_FILE="$CACHE_DIR/graph-scan.json"
mkdir -p "$CACHE_DIR"

MAX_REF_DEPTH=${MAX_REF_DEPTH:-3}
MEMORY_STALE_DAYS=${MEMORY_STALE_DAYS:-365}
TTL_SECONDS=${SCAN_GRAPH_TTL:-3600}

command -v jq >/dev/null 2>&1 || { echo '{"meta":{"partial":true,"reason":"jq missing"},"findings":[]}'; exit 0; }

if [ "$NO_CACHE" = 0 ] && [ "$REFRESH" = 0 ] && [ -s "$CACHE_FILE" ]; then
    cache_scope=$(jq -r '.meta.scope // empty' "$CACHE_FILE" 2>/dev/null || echo "")
    if [ "$cache_scope" = "$SCOPE" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$TTL_SECONDS" ]; then
            cat "$CACHE_FILE"
            exit 0
        fi
    fi
fi

TMP_DIR=$(mktemp -d)
TMP_FINDINGS="$TMP_DIR/findings.jsonl"
NODES_FILE="$TMP_DIR/nodes"
EDGES_FILE="$TMP_DIR/edges"
REFS_FILE="$TMP_DIR/refs"
for _f in "$TMP_FINDINGS" "$NODES_FILE" "$EDGES_FILE" "$REFS_FILE"; do : >"$_f"; done
trap 'rm -rf "$TMP_DIR"' EXIT

emit_finding() {
    local phase="$1" tag="$2" path="$3" message="$4"
    jq -c -n --arg s "$SCOPE" --argjson p "$phase" --arg t "$tag" --arg ph "$path" --arg m "$message" \
        '{phase:$p, tag:$t, scope:$s, path:$ph, message:$m}' >>"$TMP_FINDINGS"
}

scan_plugins() {
    [ "$IS_USER_TREE" = 1 ] || return 0
    local ip_file="$USER_TREE/plugins/installed_plugins.json"
    [ -f "$ip_file" ] || return 0
    jq -r '
        .plugins // {}
        | to_entries[]
        | .key as $k
        | .value[]?
        | "\($k)\t\(.installPath // "")\t\(.version // "")"
    ' "$ip_file" 2>/dev/null | while IFS=$'\t' read -r key ip manifest_ver; do
        [ -z "$ip" ] && continue
        if [ ! -d "$ip" ]; then
            emit_finding 2 "PLUGIN-BROKEN-REF" "$key" "installPath missing on disk: $ip"
            continue
        fi
        local pj
        pj=$(find "$ip" -maxdepth 3 -name 'plugin.json' 2>/dev/null | head -1)
        if [ -z "$pj" ]; then
            # Modern marketplaces keep plugin.json in the catalog, not the version dir.
            # Accept .mcp.json / skills/ / commands/ / agents/ as manifest-equivalent
            # evidence the plugin defines capabilities; only flag a truly empty install.
            if [ -f "$ip/.mcp.json" ] || [ -d "$ip/skills" ] || [ -d "$ip/commands" ] || [ -d "$ip/agents" ]; then
                continue
            fi
            emit_finding 2 "PLUGIN-MISSING-MANIFEST" "$key" "no plugin.json or capability dir under $ip"
            continue
        fi
        local disk_ver
        disk_ver=$(jq -r '.version // empty' "$pj" 2>/dev/null)
        if [ -n "$disk_ver" ] && [ -n "$manifest_ver" ] \
           && [ "$manifest_ver" != "$disk_ver" ] \
           && [ "$manifest_ver" != "unknown" ] \
           && [ "$disk_ver" != "unknown" ]; then
            emit_finding 2 "PLUGIN-VERSION-DRIFT" "$key" "installed=$manifest_ver, on-disk=$disk_ver"
        fi
    done
}

# Resolve a reference path mentioned inside a markdown source file. SKILL.md
# resolves refs against its own dir; references/*.md resolve siblings (same
# dir); command files (commands/foo.md) resolve against the foo/ sibling dir.
_ref_base() {
    local src="$1" cmds_dir="$2"
    case "$src" in
        "$cmds_dir"/*.md)
            local sub="${src%.md}"
            [ -d "$sub" ] && { printf '%s' "$sub"; return; }
            printf '%s' "$(dirname "$src")"
            ;;
        */references/*)
            # A reference file. Its `references/X.md` citations are written
            # relative to the owning skill/command root (the dir that CONTAINS
            # references/), not to the file's own dir — otherwise the path
            # doubles (.../references/references/X.md) and the edge never
            # resolves, which both hides ref->ref cycles/depth and falsely
            # flags a cited sibling as REF-ORPHAN.
            printf '%s' "${src%/references/*}"
            ;;
        *)
            printf '%s' "$(dirname "$src")"
            ;;
    esac
}

scan_ref_graph() {
    local skills_dir="$CLAUDE_DIR/skills" cmds_dir="$CLAUDE_DIR/commands"
    [ -d "$skills_dir" ] || [ -d "$cmds_dir" ] || return 0

    if [ -d "$skills_dir" ]; then
        for sk in "$skills_dir"/*/SKILL.md; do
            [ -f "$sk" ] || continue
            printf '%s\troot\n' "$sk" >>"$NODES_FILE"
            local sd; sd=$(dirname "$sk")
            if [ -d "$sd/references" ]; then
                while IFS= read -r r; do
                    [ -f "$r" ] || continue
                    printf '%s\tref\n' "$r" >>"$NODES_FILE"
                    printf '%s\n' "$r" >>"$REFS_FILE"
                done < <(find "$sd/references" -name '*.md' -type f 2>/dev/null)
            fi
        done
    fi
    if [ -d "$cmds_dir" ]; then
        for cf in "$cmds_dir"/*.md; do
            [ -f "$cf" ] || continue
            printf '%s\troot\n' "$cf" >>"$NODES_FILE"
            local sub="${cf%.md}"
            if [ -d "$sub/references" ]; then
                while IFS= read -r r; do
                    [ -f "$r" ] || continue
                    printf '%s\tref\n' "$r" >>"$NODES_FILE"
                    printf '%s\n' "$r" >>"$REFS_FILE"
                done < <(find "$sub/references" -name '*.md' -type f 2>/dev/null)
            fi
        done
    fi

    while IFS=$'\t' read -r src kind; do
        [ -f "$src" ] || continue
        local base
        base=$(_ref_base "$src" "$cmds_dir")
        local refs
        refs=$(grep -oE 'references/[A-Za-z0-9._/-]+\.md' "$src" 2>/dev/null | sort -u)
        while IFS= read -r r; do
            [ -z "$r" ] && continue
            local tgt="$base/$r"
            [ -f "$tgt" ] && printf '%s\t%s\n' "$src" "$tgt" >>"$EDGES_FILE"
        done <<< "$refs"
    done < <(sort -u "$NODES_FILE")

    declare -A INDEG ADJ
    while IFS=$'\t' read -r s t; do
        [ -z "$s" ] && continue
        INDEG["$t"]=$(( ${INDEG["$t"]:-0} + 1 ))
        ADJ["$s"]="${ADJ["$s"]:-} $t"
    done < "$EDGES_FILE"

    # Bare sibling references: a reference doc that cites another reference by bare
    # filename (`state-file.md`, "sibling of this file") DOES reference it. Counted
    # for REF-ORPHAN only — NOT added to ADJ — so a prose name-drop cannot fabricate
    # a false REF-CIRCULAR/REF-TOO-DEEP through the cycle/depth walk.
    declare -A SIBREF
    local sdir sib b
    while IFS=$'\t' read -r src kind; do
        [ -f "$src" ] || continue
        case "$src" in */references/*) : ;; *) continue ;; esac
        sdir=$(dirname "$src")
        while IFS= read -r b; do
            [ -z "$b" ] && continue
            sib="$sdir/$b"
            [ "$sib" = "$src" ] && continue
            [ -f "$sib" ] && SIBREF["$sib"]=1
        done < <(grep -oE '[A-Za-z0-9._-]+\.md' "$src" 2>/dev/null | sort -u)
    done < <(sort -u "$NODES_FILE")

    local ref
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        if { [ -z "${INDEG["$ref"]:-}" ] || [ "${INDEG["$ref"]:-0}" = 0 ]; } && [ -z "${SIBREF["$ref"]:-}" ]; then
            emit_finding 11 "REF-ORPHAN" "${ref#$CLAUDE_DIR/}" "no skill or command references this file"
        fi
    done < <(sort -u "$REFS_FILE")

    declare -A IN_STACK CYCLE_REPORTED
    _walk() {
        local node="$1" depth="$2" path_str="$3" root_rel="$4"
        if [ "${IN_STACK[$node]:-0}" = 1 ]; then
            if [ -z "${CYCLE_REPORTED[$node]:-}" ]; then
                emit_finding 11 "REF-CIRCULAR" "$root_rel" "cycle through $(basename "$node"): $path_str"
                CYCLE_REPORTED[$node]=1
            fi
            return
        fi
        if [ "$depth" -gt "$MAX_REF_DEPTH" ]; then
            emit_finding 11 "REF-TOO-DEEP" "${node#$CLAUDE_DIR/}" "depth $depth from $root_rel exceeds MAX_REF_DEPTH=$MAX_REF_DEPTH"
            return
        fi
        IN_STACK[$node]=1
        local child
        for child in ${ADJ[$node]:-}; do
            _walk "$child" "$((depth + 1))" "$path_str -> $(basename "$node")" "$root_rel"
        done
        IN_STACK[$node]=0
    }
    local root
    while IFS=$'\t' read -r root kind; do
        [ "$kind" = "root" ] || continue
        local root_rel="${root#$CLAUDE_DIR/}"
        unset CYCLE_REPORTED IN_STACK
        declare -A IN_STACK CYCLE_REPORTED
        _walk "$root" 0 "$root_rel" "$root_rel"
    done < <(sort -u "$NODES_FILE")
}

# Memory hygiene: only the link-index format (`- [Title](file.md)`) is checked.
# Freeform MEMORY.md files (no link entries) are left alone.
scan_memory() {
    [ "$IS_USER_TREE" = 1 ] || return 0
    local mem_root="$USER_TREE/projects"
    [ -d "$mem_root" ] || return 0
    local now_sec
    now_sec=$(date +%s)
    local mem
    while IFS= read -r mem; do
        [ -f "$mem" ] || continue
        local memdir; memdir=$(dirname "$mem")
        local rel="${mem#$USER_TREE/}"
        local linked_count
        linked_count=$(grep -cE '^- \[.+\]\([^)]+\.md\)' "$mem" 2>/dev/null || echo 0)
        [ "$linked_count" = 0 ] && continue

        local seen_targets_file="$TMP_DIR/seen.$$"
        : >"$seen_targets_file"
        local line tgt
        grep -nE '^- \[.+\]\([^)]+\.md\)' "$mem" 2>/dev/null | while IFS= read -r line; do
            tgt=$(printf '%s' "$line" | sed -nE 's/.*\(([^)]+\.md)\).*/\1/p')
            [ -z "$tgt" ] && continue
            local linkno="${line%%:*}"
            local full="$memdir/$tgt"
            if [ ! -f "$full" ]; then
                emit_finding 20 "MEMORY-DEAD-LINK" "$rel" "line $linkno: $tgt missing on disk"
            fi
            if grep -qFx "$tgt" "$seen_targets_file" 2>/dev/null; then
                emit_finding 20 "MEMORY-DUP-ENTRY" "$rel" "line $linkno: $tgt linked more than once"
            else
                printf '%s\n' "$tgt" >>"$seen_targets_file"
            fi
        done

        if [ -s "$seen_targets_file" ]; then
            local memfile
            while IFS= read -r memfile; do
                [ -f "$memfile" ] || continue
                local memrel="${memfile#$USER_TREE/}"
                local bn; bn=$(basename "$memfile")
                [ "$bn" = "MEMORY.md" ] && continue
                if ! grep -qFx "$bn" "$seen_targets_file"; then
                    emit_finding 20 "MEMORY-ORPHAN-FILE" "$memrel" "no MEMORY.md entry links to $bn"
                fi
            done < <(find "$memdir" -maxdepth 1 -name '*.md' -type f 2>/dev/null)
        fi
        rm -f "$seen_targets_file"

        local datestr y m d epoch age_days
        grep -oE '20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])' "$mem" 2>/dev/null | sort -u | while IFS= read -r datestr; do
            y="${datestr%%-*}"
            m=$(printf '%s' "$datestr" | cut -d- -f2)
            d=$(printf '%s' "$datestr" | cut -d- -f3)
            epoch=$(date -d "$y-$m-$d" +%s 2>/dev/null || echo 0)
            [ "$epoch" = 0 ] && continue
            age_days=$(( (now_sec - epoch) / 86400 ))
            if [ "$age_days" -gt "$MEMORY_STALE_DAYS" ]; then
                emit_finding 20 "MEMORY-STALE-DATE" "$rel" "$datestr is $age_days days old (> $MEMORY_STALE_DAYS)"
            fi
        done
    done < <(find "$mem_root" -mindepth 3 -maxdepth 3 -name 'MEMORY.md' -type f 2>/dev/null)
}

# Output-style hygiene: a settings `outputStyle` naming a style with no file
# (and not a built-in) is a dead selection. Built-in styles ship with Claude
# Code and have no file; documented values are capitalized (e.g. "Explanatory"),
# so the match is case-insensitive. Runs on any tree.
OUTPUT_STYLE_BUILTINS="default proactive explanatory learning"
scan_output_styles() {
    local styles_dir="$CLAUDE_DIR/output-styles"
    local selected="" sf v sel_lc
    for sf in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
        [ -f "$sf" ] || continue
        v=$(jq -r '.outputStyle // empty' "$sf" 2>/dev/null)
        [ -n "$v" ] && selected="$v"
    done
    [ -n "$selected" ] || return 0
    sel_lc=$(printf '%s' "$selected" | tr '[:upper:]' '[:lower:]')
    case " $OUTPUT_STYLE_BUILTINS " in
        *" $sel_lc "*) return 0 ;;
    esac
    if [ ! -f "$styles_dir/$selected.md" ]; then
        emit_finding 26 "OUTPUTSTYLE-MISSING" "settings.json" "outputStyle '$selected' has no file at output-styles/$selected.md and is not a built-in style"
    fi
}

# MCP transport hygiene: the `sse` transport is deprecated in favour of
# `http`/`streamable-http`. Flag any mcpServers entry of type "sse" across the
# project/user MCP config files. Runs on any tree.
scan_mcp() {
    local f rel srv
    for f in "$CLAUDE_DIR/.mcp.json" "$CLAUDE_DIR/../.mcp.json" "$CLAUDE_DIR/../.claude.json" \
             "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
        [ -f "$f" ] || continue
        rel="${f#$CLAUDE_DIR/}"
        case "$f" in "$CLAUDE_DIR/../"*) rel="${f##*/}" ;; esac
        while IFS= read -r srv; do
            [ -z "$srv" ] && continue
            emit_finding 2 "MCP-DEPRECATED-TRANSPORT" "$rel" "MCP server '$srv' uses deprecated sse transport — migrate to http/streamable-http"
        done < <(jq -r '(.mcpServers // {}) | to_entries[] | select((.value.type // "") == "sse") | .key' "$f" 2>/dev/null || true)
    done
}

# Validate a plugin repo's OWN manifest + structure when CLAUDE_DIR is a plugin
# root (contains .claude-plugin/plugin.json). Phase 2 band; independent of scope —
# lets the tool dogfood on any plugin tree, not just installed user-tree plugins.
scan_plugin_self() {
    local pdir="$CLAUDE_DIR/.claude-plugin" pj comp ver mp src resolved p proot rel
    pj="$pdir/plugin.json"
    [ -f "$pj" ] || return 0

    # Component dirs must sit at the plugin root, never inside .claude-plugin/.
    for comp in skills agents commands hooks output-styles monitors; do
        [ -d "$pdir/$comp" ] \
            && emit_finding 2 "PLUGIN-MISPLACED-DIR" ".claude-plugin/$comp" "component dir '$comp' is inside .claude-plugin/ — it must sit at the plugin root"
    done

    # version must be present and semantic, else Claude Code falls back to the git
    # SHA and treats every commit as a new version.
    ver=$(jq -r '.version // empty' "$pj" 2>/dev/null)
    if [ -z "$ver" ]; then
        emit_finding 2 "PLUGIN-BAD-VERSION" ".claude-plugin/plugin.json" "no 'version' field — Claude Code falls back to the git SHA, so every commit reads as a new version"
    elif ! printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$'; then
        emit_finding 2 "PLUGIN-BAD-VERSION" ".claude-plugin/plugin.json" "version '$ver' is not semantic (expected MAJOR.MINOR.PATCH)"
    fi

    # Declared component paths must be relative and start with ./.
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
            ./*) : ;;
            *) emit_finding 2 "PLUGIN-ABS-PATH" ".claude-plugin/plugin.json" "path '$p' must be relative and start with ./" ;;
        esac
    done < <(jq -r '[ .skills, .commands, .agents, .outputStyles, .lspServers ]
                    | map(if type=="array" then .[] elif type=="string" then . else empty end) | .[]?
                    | select(type=="string")' "$pj" 2>/dev/null || true)

    # marketplace.json string sources are LOCAL paths (object sources are remote — skipped
    # by jq). A string resolves relative to the marketplace root, optionally under
    # metadata.pluginRoot (which lets an entry omit the ./ prefix). Only flag a local path
    # that resolves to no directory.
    mp="$pdir/marketplace.json"
    if [ -f "$mp" ]; then
        proot=$(jq -r '.metadata.pluginRoot // empty' "$mp" 2>/dev/null)
        while IFS= read -r src; do
            [ -z "$src" ] && continue
            case "$src" in http*|git@*) continue ;; esac
            rel="$src"
            [ -n "$proot" ] && case "$src" in ./*|/*) : ;; *) rel="$proot/$src" ;; esac
            case "$rel" in /*) resolved="$rel" ;; *) resolved="$CLAUDE_DIR/$rel" ;; esac
            [ -d "$resolved" ] \
                || emit_finding 2 "MARKETPLACE-DEAD-SOURCE" ".claude-plugin/marketplace.json" "plugin source '$src' does not resolve to a directory"
        done < <(jq -r '.plugins[]? | (.source // empty) | if type=="string" then . else empty end' "$mp" 2>/dev/null || true)
    fi
}

GEN_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
scan_plugins
scan_plugin_self
scan_ref_graph
scan_memory
scan_output_styles
scan_mcp

NUM_FINDINGS=$(wc -l <"$TMP_FINDINGS" | tr -d ' ')
META=$(jq -n --arg gen "$GEN_AT" --arg s "$SCOPE" --arg cd "$CLAUDE_DIR" --argjson n "${NUM_FINDINGS:-0}" \
    '{generated_at:$gen, scope:$s, claude_dir:$cd, findings_count:$n, partial:false}')

OUT_TMP="$CACHE_FILE.tmp"
jq -s --argjson meta "$META" '{meta:$meta, findings:.}' "$TMP_FINDINGS" >"$OUT_TMP"
mv -f "$OUT_TMP" "$CACHE_FILE"
cat "$CACHE_FILE"
