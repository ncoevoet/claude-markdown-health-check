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

# A plugin key is `<name>@<marketplace>`. Returns 0 when that marketplace's catalog
# entry declares the plugin's capabilities inline — lspServers / mcpServers / hooks /
# outputStyles — or marks it non-strict. Such a plugin ships no plugin.json by design
# (e.g. typescript-lsp: lspServers + "strict": false, version dir holds only LICENSE
# and README), so the absence of a manifest is not a defect.
_marketplace_declares_capabilities() {
    local key="$1" name="${1%@*}" mkt="${1##*@}" catalog
    [ "$name" = "$key" ] && return 1
    catalog="$USER_TREE/plugins/marketplaces/$mkt/.claude-plugin/marketplace.json"
    [ -f "$catalog" ] || return 1
    jq -e --arg n "$name" '
        (.plugins // [])
        | map(select(.name == $n))
        | .[0] // empty
        | select(has("lspServers") or has("mcpServers") or has("hooks")
                 or has("outputStyles") or (.strict == false))
    ' "$catalog" >/dev/null 2>&1
}

scan_plugins() {
    [ "$IS_USER_TREE" = 1 ] || return 0
    local ip_file="$USER_TREE/plugins/installed_plugins.json"
    [ -f "$ip_file" ] || return 0
    # Install keys are `<name>@<marketplace>`; a `dependencies` entry names the plugin
    # only, so compare against the bare names.
    local installed_names
    installed_names=$(jq -r '(.plugins // {}) | keys[]' "$ip_file" 2>/dev/null | sed 's/@.*//' | sort -u)
    # \u001f, not \t: tab is IFS whitespace, so bash collapses a run of tabs into one
    # delimiter and an empty installPath would shift the version into $ip.
    jq -r '
        .plugins // {}
        | to_entries[]
        | .key as $k
        | .value[]?
        | "\($k)\u001f\(.installPath // "")\u001f\(.version // "")"
    ' "$ip_file" 2>/dev/null | while IFS=$'\x1f' read -r key ip manifest_ver; do
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
            if _marketplace_declares_capabilities "$key"; then
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
        # A declared dependency that is not installed leaves the plugin half-wired.
        # Version constraints are not evaluated — only presence.
        local dep
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            printf '%s\n' "$installed_names" | grep -qxF -- "$dep" && continue
            emit_finding 2 "PLUGIN-MISSING-DEPENDENCY" "$key" "declares dependency '$dep', which is not installed"
        done < <(jq -r '(.dependencies // []) | if type=="array" then .[] else empty end
                        | if type=="string" then . elif type=="object" then (.name // empty) else empty end' "$pj" 2>/dev/null || true)
    done

    # MARKETPLACE-BLOCKED: a plugin whose marketplace settings.json blocks — outright
    # via blockedMarketplaces, or by omission when strictKnownMarketplaces is on —
    # stays on disk but is never loaded.
    local settings_file="$USER_TREE/settings.json"
    local blocked strict extra known mkt
    if [ -f "$settings_file" ]; then
        blocked=$(jq -r '(.blockedMarketplaces // []) | if type=="array" then .[] else empty end' "$settings_file" 2>/dev/null)
        strict=$(jq -r 'if .strictKnownMarketplaces == true then "1" else "0" end' "$settings_file" 2>/dev/null)
        extra=$(jq -r '(.extraKnownMarketplaces // []) | if type=="array" then (.[] | if type=="string" then . else (.name // empty) end) else empty end' "$settings_file" 2>/dev/null)
        known=$(jq -r 'if type=="object" then keys[] else empty end' "$USER_TREE/plugins/known_marketplaces.json" 2>/dev/null)
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            mkt="${key##*@}"
            [ "$mkt" = "$key" ] && continue
            if printf '%s\n' "$blocked" | grep -qxF -- "$mkt"; then
                emit_finding 2 "MARKETPLACE-BLOCKED" "$key" "marketplace '$mkt' is in blockedMarketplaces — the plugin stays on disk but never loads"
                continue
            fi
            [ "$strict" = "1" ] || continue
            printf '%s\n' "$known" | grep -qxF -- "$mkt" && continue
            printf '%s\n' "$extra" | grep -qxF -- "$mkt" && continue
            emit_finding 2 "MARKETPLACE-BLOCKED" "$key" "strictKnownMarketplaces is on and marketplace '$mkt' is neither known nor in extraKnownMarketplaces — the plugin never loads"
        done < <(jq -r '(.plugins // {}) | keys[]' "$ip_file" 2>/dev/null || true)
    fi

    # PLUGIN-DISABLED: a plugin installed at user scope but absent from
    # settings.json#enabledPlugins is parked — loaded by nothing, still on disk.
    # A pure uninstall candidate (or an intentional park). Only run when an
    # enabledPlugins map exists; without it, enable-state is indeterminate.
    [ -f "$settings_file" ] || return 0
    jq -e '.enabledPlugins' "$settings_file" >/dev/null 2>&1 || return 0
    local enabled_keys
    enabled_keys=$(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value==true) | .key' "$settings_file" 2>/dev/null)
    local dpj
    jq -r '
        .plugins // {}
        | to_entries[]
        | .key as $k
        | .value[]?
        | select((.scope // "user") == "user")
        | "\($k)\t\(.installPath // "")"
    ' "$ip_file" 2>/dev/null | sort -u | while IFS=$'\t' read -r key ip; do
        [ -z "$key" ] && continue
        printf '%s\n' "$enabled_keys" | grep -qxF -- "$key" && continue
        # defaultEnabled:false ships the plugin parked by design — installing it
        # without enabling it is then the documented behaviour, not a defect.
        if [ -n "$ip" ] && [ -d "$ip" ]; then
            dpj=$(find "$ip" -maxdepth 3 -name 'plugin.json' 2>/dev/null | head -1)
            # `.defaultEnabled // empty` would swallow the false, so test it explicitly.
            [ -n "$dpj" ] && [ "$(jq -r 'if .defaultEnabled == false then "false" else "" end' "$dpj" 2>/dev/null)" = "false" ] && continue
        fi
        emit_finding 2 "PLUGIN-DISABLED" "$key" "installed (user scope) but not enabled in settings.json — uninstall to reclaim disk if unused"
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

# Lexically normalise a manifest component path against the plugin root. Pure string work
# (no realpath/readlink -m, which macOS lacks; nothing touches the filesystem, so a missing
# path still normalises and symlinks are not followed). $2 is the physical plugin root.
# Prints the root-relative form ("" = the root itself, no leading ./ or trailing /) and
# returns 1 when the path leaves the root: a `..` that climbs above it, or an absolute
# path outside it. A `..` that stays inside the root is fine here.
_plugin_path_norm() {
    local p="$1" root="$2" rest seg s=""
    rest="$p/"
    while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        rest="${rest#*/}"
        case "$seg" in
            ""|.) ;;
            ..)
                if [ -n "$s" ]; then s="${s%/*}"
                else case "$p" in /*) ;; *) return 1 ;; esac
                fi ;;
            *) s="$s/$seg" ;;
        esac
    done
    case "$p" in
        /*)
            if [ "$s" = "$root" ]; then s=""
            else case "$s" in "$root"/*) s="${s#"$root"/}" ;; *) return 1 ;; esac
            fi
            printf '%s' "$s" ;;
        *) printf '%s' "${s#/}" ;;
    esac
}

# Did-you-mean for an unknown key: succeeds, printing the documented key, when the key
# equals a known one after lower-casing and dropping `_` and `-` (descriptionURL, Home_Page).
_manifest_key_suggest() {
    local key="$1" known="$2" want cand k
    want=$(printf '%s' "$key" | tr 'A-Z' 'a-z' | tr -d '_-')
    for k in $known; do
        cand=$(printf '%s' "$k" | tr 'A-Z' 'a-z' | tr -d '_-')
        [ "$cand" = "$want" ] && { printf '%s' "$k"; return 0; }
    done
    return 1
}

# Plugin manifest key checks (phase 2). Runs when CLAUDE_DIR holds a .claude-plugin/plugin.json
# and/or marketplace.json, any scope, like scan_plugin_self. Key sets below were read from
# https://code.claude.com/docs/en/plugins/manifest-reference (plugins-reference) and
# .../plugins/marketplace-reference on 2026-10-06; refresh them from the `Fields`, `User
# configuration`, `Channels`, `lspServers`, `monitors`, `Top-level fields` and `Plugin entries`
# tables when the docs move (recipe in plugin/references/plugin-integrity.md).
scan_plugin_manifest_keys() {
    local pdir="$CLAUDE_DIR/.claude-plugin" pj mp root
    pj="$pdir/plugin.json"; mp="$pdir/marketplace.json"
    [ -f "$pj" ] || [ -f "$mp" ] || return 0
    local sep=$'\x1f' loc key sug dir fld ek p n entries hit

    # manifest-reference `Fields` table: "The table lists the top-level keys in `plugin.json`."
    # `themes` and `monitors` are kept: "A top-level `themes` key still loads, with a
    # `claude plugin validate` warning" (same for `monitors`), so they are deprecated, not unknown.
    local PJ_KEYS='$schema name displayName version description author homepage repository license keywords metadata icon documentationUrl supportUrl privacyPolicyUrl termsOfServiceUrl defaultEnabled dependencies settings userConfig types channels skills commands agents hooks mcpServers lspServers outputStyles workflows experimental themes monitors'
    # "## User configuration": "Each value is a strict object with these fields. An unknown key fails validation."
    # (`min` / `max` share one table row.)
    local UC_KEYS='type title description required default options multiple sensitive min max'
    # "## Channels": "Each entry is a strict object bound to one of the plugin's MCP servers, with these fields:"
    local CH_KEYS='server displayName userConfig'
    # "### `lspServers`": "Each server config is a strict object with these fields. An unknown key fails validation."
    local LSP_KEYS='command extensionToLanguage args transport env initializationOptions settings workspaceFolder startupTimeout shutdownTimeout requestTimeout restartOnCrash maxRestarts diagnostics'
    # "### `monitors`": "Each entry is a strict object with these fields."
    local MON_KEYS='name command description when'
    # marketplace-reference "Top-level fields": "The table lists every key Claude Code reads from `marketplace.json`."
    local MP_KEYS='name owner plugins $schema description version metadata forceRemoveDeletedPlugins allowCrossMarketplaceDependenciesOn renames'
    # "Plugin entries": an entry "also accepts every `plugin.json` field" apart from the directory
    # listing fields (icon, documentationUrl, supportUrl, privacyPolicyUrl, termsOfServiceUrl: "In a
    # marketplace entry, `claude plugin validate` reports each one as an unknown field"), plus its own.
    local ENTRY_KEYS='name source description version category tags strict relevance dependencies defaultEnabled displayName metadata headers headersHelper $schema author homepage repository license keywords settings userConfig types channels skills commands agents hooks mcpServers lspServers outputStyles workflows experimental themes monitors'

    if [ -f "$pj" ]; then
        # Unrecognised top-level keys. manifest-reference "Unrecognized fields": "the field is
        # stripped and the plugin loads. `claude plugin validate` reports each unrecognized
        # top-level field as a warning".
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            sug=$(_manifest_key_suggest "$key" "$PJ_KEYS") && sug=" — did you mean '$sug'?"
            emit_finding 2 "PLUGIN-UNKNOWN-KEY" ".claude-plugin/plugin.json" "unrecognized top-level key '$key' is stripped at load${sug:-}"
            sug=""
        done < <(jq -r --arg known "$PJ_KEYS" 'objects | keys_unsorted[] | select(. as $k | ($known | split(" ") | index($k)) == null)' "$pj" 2>/dev/null || true)

        # Strict objects. manifest-reference: "`userConfig` options, `channels` entries, `lspServers`
        # configs, and `monitors` entries are strict. An unknown key inside one is an error, and the
        # plugin doesn't load". Only inline definitions are visible here (a .json file named by
        # `lspServers` is not read).
        while IFS="$sep" read -r loc key; do
            [ -z "$key" ] && continue
            emit_finding 2 "PLUGIN-STRICT-OBJECT-UNKNOWN-KEY" ".claude-plugin/plugin.json" "$loc has unknown key '$key' — strict object, an unknown key is an error and the plugin doesn't load"
        done < <(jq -r --arg uc "$UC_KEYS" --arg ch "$CH_KEYS" --arg lsp "$LSP_KEYS" --arg mon "$MON_KEYS" '
            def unknown($loc; $known):
                objects | keys_unsorted[] | select(. as $k | ($known | split(" ") | index($k)) == null) | "\($loc)\u001f\(.)";
            def options($loc):
                objects | to_entries[] | select(.value | type == "object") | .key as $o | .value | unknown("\($loc).\($o)"; $uc);
            def monitors: arrays | to_entries[] | select(.value | type == "object") | .key as $i | .value | unknown("monitors[\($i)]"; $mon);
            objects
            | ( (.userConfig | options("userConfig")),
                ( .channels | arrays | to_entries[] | select(.value | type == "object") | .key as $i | .value
                  | unknown("channels[\($i)]"; $ch), (.userConfig | options("channels[\($i)].userConfig")) ),
                ( .lspServers | (if type == "object" then [.] elif type == "array" then [.[] | objects] else [] end)[]
                  | to_entries[] | select(.value | type == "object") | .key as $n | .value | unknown("lspServers.\($n)"; $lsp) ),
                ( (.experimental | objects | .monitors | monitors), (.monitors | monitors) ) )' "$pj" 2>/dev/null || true)

        # Component paths. manifest-reference "Containment and existence": "a path that resolves
        # outside the plugin root doesn't load, and the `/plugin` Errors tab shows `<component> path
        # escapes plugin directory: <path>`. A path containing `..` is the usual case". A `..` that
        # stays inside the root loads (validate-only error) and is not flagged. Each line is
        # `key<US>path`; a path-less line marks a key that is set (its value may be inline config).
        root=$(cd -P "$CLAUDE_DIR" 2>/dev/null && pwd -P)
        entries=$(jq -r '
            def paths($k):
                if type == "string" then .
                elif type == "array" then .[] | if type == "string" then . elif type == "object" and $k == "commands" then (.source? | strings) else empty end
                elif type == "object" and $k == "commands" then .[]? | objects | (.source? | strings)
                else empty end;
            objects | . as $r
            | ( ("skills","commands","agents","outputStyles","workflows","hooks","mcpServers","lspServers") as $k | select(has($k)) | [$k, .[$k]] ),
              ( .experimental | objects | to_entries[] | ["experimental." + .key, .value] )
            | .[0] as $k | "\($k)\u001f", (.[1] | paths($k) | select(startswith("http://") or startswith("https://") | not) | "\($k)\u001f\(.)")' "$pj" 2>/dev/null || true)
        while IFS="$sep" read -r key p; do
            [ -z "$p" ] && continue
            _plugin_path_norm "$p" "$root" >/dev/null \
                || emit_finding 2 "PLUGIN-PATH-ESCAPE" ".claude-plugin/plugin.json" "$key path '$p' resolves outside the plugin root — it doesn't load (path escapes plugin directory)"
        done <<<"$entries"

        # Default folders a key replaces. manifest-reference "How each key combines with its
        # default location": "**Replaces the default**: `commands`, `agents`, `outputStyles`,
        # `workflows`, `experimental.themes`, `experimental.monitors`. When you set `commands`, the
        # default `commands/` directory isn't scanned." and "To avoid the warning, set the key to a
        # path inside that folder". `skills` ("Adds to the default") and `hooks`/`mcpServers`/
        # `lspServers` ("Merges") are never flagged.
        for fld in commands:commands agents:agents outputStyles:output-styles workflows:workflows experimental.themes:themes experimental.monitors:monitors; do
            key="${fld%%:*}"; dir="${fld#*:}"
            [ -d "$CLAUDE_DIR/$dir" ] || continue
            printf '%s\n' "$entries" | grep -qxF "$key$sep" || continue
            hit=0
            while IFS="$sep" read -r ek p; do
                [ "$ek" = "$key" ] && [ -n "$p" ] || continue
                n=$(_plugin_path_norm "$p" "$root") || continue
                case "$n" in ""|"$dir"|"$dir"/*) hit=1 ;; esac
            done <<<"$entries"
            [ "$hit" = 1 ] \
                || emit_finding 2 "PLUGIN-DEFAULT-DIR-SHADOWED" ".claude-plugin/plugin.json" "Default $dir/ folder is ignored because the manifest sets \"$key\" — list \"./$dir/\" in it to keep the folder"
        done
    fi

    if [ -f "$mp" ]; then
        # marketplace-reference: "Claude Code ignores an unknown top-level key or plugin-entry key
        # rather than rejecting it, so a typo loads silently. `claude plugin validate` reports each
        # unknown key as a warning." `metadata` and an entry's `relevance` are free objects.
        while IFS="$sep" read -r loc key; do
            [ -z "$key" ] && continue
            if [ "$loc" = "top-level" ]; then sug=$(_manifest_key_suggest "$key" "$MP_KEYS")
            else sug=$(_manifest_key_suggest "$key" "$ENTRY_KEYS"); fi && sug=" — did you mean '$sug'?"
            emit_finding 2 "MARKETPLACE-UNKNOWN-KEY" ".claude-plugin/marketplace.json" "unknown $loc key '$key' is ignored at load time${sug:-}"
            sug=""
        done < <(jq -r --arg top "$MP_KEYS" --arg ent "$ENTRY_KEYS" '
            objects
            | ( keys_unsorted[] | select(. as $k | ($top | split(" ") | index($k)) == null) | "top-level\u001f\(.)" ),
              ( .plugins | arrays | .[] | objects | keys_unsorted[] | select(. as $k | ($ent | split(" ") | index($k)) == null) | "plugin-entry\u001f\(.)" )' "$mp" 2>/dev/null || true)
    fi
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
        # Anchor the match to a path boundary: a bare `references/X.md` is a real
        # citation, but the `references/X.md` tail of a cross-skill path mentioned
        # in prose (e.g. `other-skill/references/X.md`) must NOT resolve against
        # THIS skill's dir — that fabricated a self-edge and a false REF-CIRCULAR.
        refs=$(grep -oE '(^|[^A-Za-z0-9._/-])references/[A-Za-z0-9._/-]+\.md' "$src" 2>/dev/null \
               | grep -oE 'references/[A-Za-z0-9._/-]+\.md' | sort -u)
        while IFS= read -r r; do
            [ -z "$r" ] && continue
            local tgt="$base/$r"
            [ "$tgt" = "$src" ] && continue
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

# Output-style hygiene (Phase 26). Runs on any tree.
#   OUTPUTSTYLE-MISSING — `outputStyle` names no style: not a built-in, and no
#                         output-styles/*.md whose frontmatter `name:` (else file name) equals it.
#   OUTPUTSTYLE-CASE    — the value matches a style only case-insensitively. The settings
#                         value is case-sensitive, so Claude Code falls back to Default.
# Built-ins are exactly the documented spellings; lowercase `default` is tolerated because
# output-styles.md lists `default` among the `/output-style` entries, so it is selected the same way.
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

# The style files of one root (a .claude tree or a plugin root). A plugin manifest's
# `outputStyles` (files or directories, relative, no `..`) REPLACES the default output-styles/ scan.
_output_style_files() {
    local root="$1" pj="$1/.claude-plugin/plugin.json" entry p f has=0
    if [ -f "$pj" ] && jq -e 'has("outputStyles")' "$pj" >/dev/null 2>&1; then
        has=1
        while IFS= read -r entry; do
            case "$entry" in /*|*..*) continue ;; esac
            p="$root/${entry#./}"
            if [ -d "$p" ]; then
                for f in "$p"/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done
            elif [ -f "$p" ]; then
                printf '%s\n' "$p"
            fi
        done < <(jq -r '.outputStyles | if type == "array" then .[] else . end | strings' "$pj" 2>/dev/null)
    fi
    [ "$has" = 1 ] && return 0
    for f in "$root"/output-styles/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done
    return 0
}

# Every root whose styles Claude Code would load for this tree: the scanned one, the user's,
# each ancestor project's up to the repository root (docs: "every .claude/output-styles/
# between the working directory and the repository root"), and, in the user tree, every
# installed plugin.
_output_style_roots() {
    local d
    printf '%s\n' "$CLAUDE_DIR" "$USER_TREE"
    if [ "$IS_USER_TREE" = 1 ] && [ -f "$USER_TREE/plugins/installed_plugins.json" ]; then
        jq -r '.plugins // {} | to_entries[] | .value[]? | .installPath // empty' \
            "$USER_TREE/plugins/installed_plugins.json" 2>/dev/null
    fi
    d=$(cd "$CLAUDE_DIR/.." 2>/dev/null && pwd -P) || return 0
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        printf '%s\n' "$d/.claude"
        { [ -e "$d/.git" ] || [ "$d" = "$HOME" ]; } && break
        d=$(dirname "$d")
    done
}

scan_output_styles() {
    local selected="" sf v root f names="" b hit="" sel_lc b_lc
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
    while IFS= read -r root; do
        [ -d "$root" ] || continue
        while IFS= read -r f; do
            names+="$(_output_style_name "$f")"$'\n'
        done < <(_output_style_files "$root")
    done < <(_output_style_roots)
    if printf '%s' "$names" | grep -qxF -- "$selected"; then
        return 0
    fi
    sel_lc=$(printf '%s' "$selected" | tr '[:upper:]' '[:lower:]')
    for b in $OUTPUT_STYLE_BUILTINS; do
        b_lc=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
        [ "$b_lc" = "$sel_lc" ] && hit="$b"
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
# Only the scanned tree's own style files are checked (never the user tree, ancestors or other plugins).
scan_output_style_files() {
    local f rel fm key norm want suggestion plugin_root=0
    [ -f "$CLAUDE_DIR/.claude-plugin/plugin.json" ] && plugin_root=1
    while IFS= read -r f; do
        rel="${f#"$CLAUDE_DIR"/}"
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
    done < <(_output_style_files "$CLAUDE_DIR")
}

# MCP server hygiene across the project/user MCP config files. Runs on any tree.
#   MCP-DEPRECATED-TRANSPORT — `sse` is deprecated in favour of `http`/`streamable-http`.
#   MCP-BAD-DEF              — entry with neither `command` (stdio) nor `url` (remote); cannot start.
#   MCP-PLAINTEXT-SECRET    — a hardcoded credential in an `env`/`headers` value. Mirrors
#                             validate-skills.sh check_embedded_secrets; `${VAR}` and other
#                             placeholders are skipped, so `"Bearer ${TOKEN}"` is clean.
MCP_SECRET_RE='\b(sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,})'
MCP_PLACEHOLDER_RE='(example|placeholder|your[-_]?(key|token|secret|api)|<your|xxxx|0000|redacted|replace[-_]?me|\$\{?[A-Z][A-Z0-9_]*\}?)'

scan_mcp() {
    local f rel srv val snippet
    for f in "$CLAUDE_DIR/.mcp.json" "$CLAUDE_DIR/../.mcp.json" "$CLAUDE_DIR/../.claude.json" \
             "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
        [ -f "$f" ] || continue
        rel="${f#$CLAUDE_DIR/}"
        case "$f" in "$CLAUDE_DIR/../"*) rel="${f##*/}" ;; esac

        while IFS= read -r srv; do
            [ -z "$srv" ] && continue
            emit_finding 2 "MCP-DEPRECATED-TRANSPORT" "$rel" "MCP server '$srv' uses deprecated sse transport — migrate to http/streamable-http"
        done < <(jq -r '(.mcpServers // {}) | to_entries[] | select((.value|type)=="object") | select((.value.type // "") == "sse") | .key' "$f" 2>/dev/null || true)

        while IFS= read -r srv; do
            [ -z "$srv" ] && continue
            emit_finding 2 "MCP-BAD-DEF" "$rel" "MCP server '$srv' declares neither a command (stdio) nor a url (http/sse) — it cannot start"
        done < <(jq -r '(.mcpServers // {}) | to_entries[] | select((.value|type)=="object") | select(((.value.command // "") == "") and ((.value.url // "") == "")) | .key' "$f" 2>/dev/null || true)

        while IFS=$'\t' read -r srv val; do
            [ -z "$srv" ] && continue
            printf '%s' "$val" | grep -qiE "$MCP_PLACEHOLDER_RE" && continue
            if printf '%s' "$val" | grep -qE "$MCP_SECRET_RE"; then
                snippet=$(printf '%s' "$val" | grep -oE "$MCP_SECRET_RE" | head -1 | cut -c1-10)
                emit_finding 2 "MCP-PLAINTEXT-SECRET" "$rel" "MCP server '$srv' embeds a credential (${snippet}…) in env/headers — use \${ENV_VAR} interpolation instead"
            fi
        done < <(jq -r '(.mcpServers // {}) | to_entries[] | .key as $srv | (.value | select(type=="object"))
                        | [ (.env // {}), (.headers // {}) ]
                        | map(select(type=="object") | to_entries[] | .value | select(type=="string"))
                        | .[] | "\($srv)\t\(.)"' "$f" 2>/dev/null || true)
    done
}

# ── L5: MCP config placement ────────────────────────────────────────────────
#   MCP-MISPLACED      — a config Claude Code never reads: `.claude/.mcp.json`, a project-root
#                        `.mcp.json` whose servers sit under `servers` (VS Code shape) with no
#                        `mcpServers`, or an `mcpServers` key in settings.json/settings.local.json.
#   MCP-RELATIVE-PATH  — `command`/`args` is a relative file path (`./x`, `scripts/x`): it resolves
#                        against the launch directory, not against the .mcp.json. `~/.claude.json`
#                        is read at the top level and under every `projects.<path>`.
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
            def servers: if type == "object" then . else {} end;
            ( ((.mcpServers // {}) | servers)
              + ( [ (.projects // {}) | if type == "object" then .[] else empty end
                    | select(type == "object") | (.mcpServers // {}) | servers ] | add // {} ) )
            | to_entries[] | select(.value | type == "object") | .key as $k
            | ( [ (.value.command // empty), ((.value.args // []) | if type == "array" then .[] else empty end) ]
                | map(select(type == "string"))
                | map(select(test($re))) ) as $args
            | ( (.value.command // "") | if type == "string" and test("^[A-Za-z0-9_.-]+/") then [.] else [] end ) as $cmd
            | ($args + $cmd) | select(length > 0) | "\($k)\t\(.[0])"' "$f" 2>/dev/null || true)
    done
}

# Emit `display<TAB>command` for every shell command a hooks-shaped or monitors-shaped
# JSON document declares. Handles the three layouts: inline `hooks` (plugin.json or
# hooks/hooks.json), inline `experimental.monitors`, and a bare monitors array.
_plugin_shell_commands() {
    local f="$1" display="$2"
    [ -f "$f" ] || return 0
    jq -r --arg d "$display" '
        (if type == "object" then . else {} end) as $o
        | [ ( ($o.hooks // {}) | if type == "object"
                then [ to_entries[] | .value[]? | (.hooks // [])[]? | (.command // empty) ] else [] end ),
            ( ($o.experimental // {}) | if type == "object"
                then ((.monitors // []) | if type == "array" then [ .[]? | (.command // empty) ] else [] end) else [] end ),
            ( ($o.monitors // []) | if type == "array" then [ .[]? | (.command // empty) ] else [] end ),
            ( if type == "array" then [ .[]? | if type == "object" then (.command // empty) else empty end ] else [] end ) ]
        | add | .[]? | select(type == "string" and . != "") | "\($d)\t\(.)"' "$f" 2>/dev/null || true
}

# ── L7: plugin and marketplace names ────────────────────────────────────────
# Rule tables: plugins/manifest-reference#name and plugins/marketplace-reference#reserved-names.
#   PLUGIN-RESERVED-NAME       (Structural) — passes as one of Anthropic's own: prefix claude-/anthropic-/
#                              anthropics-/cc-plugin-, exact claude/anthropic/anthropics/claude-code/
#                              claude-mods, or `official` beside claude/anthropic. claude plugin
#                              init/tag refuse it; install and load still work.
#   PLUGIN-NAME-LOOKALIKE      (Hygiene)    — claude/anthropic/anthropics as a whole word elsewhere (warning).
#   PLUGIN-NAME-FORMAT         (Structural) — empty, or a space, @, :, path separator, control or
#                              bidirectional-formatting character, or a leading `-` (heuristic, not in the
#                              docs: `claude plugin install -x` would parse it as an option).
#   PLUGIN-NAME-NOT-KEBAB      (Hygiene)    — valid but not lower-case kebab-case.
#   MARKETPLACE-NAME-FORMAT    (Critical)   — not letters/digits/./_/-, not starting alphanumeric, contains `..`,
#                              or a control/bidi character: nothing can be installed from it.
#   MARKETPLACE-NAME-RESERVED  (Critical)   — reserved or impersonating name, any casing/spelling variant.
# A marketplace entry's `name` gets the plugin rules plus the plugin-id alphabet.
# Limits: the github.com/anthropics/ exemption is not evaluated (no git-remote parsing); the impersonation
# heuristic goes no further than the documented examples; a missing `name` is left to claude plugin validate.
# Control and bidi characters are matched by jq (already a hard dependency): its \u ranges are multibyte-safe
# and need neither grep -P (absent on macOS) nor a UTF-8 locale. The docs do not enumerate the set, so it is
# C0, DEL, C1 and the Unicode bidi formatting characters (ALM, LRM, RLM, LRE..RLO, LRI..PDI).
NAME_BAD_JQ='test("[\u0001-\u001f\u007f-\u009f؜‎‏‪-‮⁦-⁩]")'
MKT_RESERVED_NAMES="claude-code-marketplace claude-code-plugins claude-plugins-official anthropic-marketplace anthropic-plugins agent-skills anthropic-agent-skills life-sciences knowledge-work-plugins claude-for-legal claude-for-financial-services financial-services-plugins first-party-plugins claude-tag-plugins claude-community claude-plugins-community healthcare anthropic-plugin-directory claude-plugin-directory inline builtin skills-dir synced claude-plugin-test npm pip uv cargo github gh"

# Prints "error" | "warning" | nothing for a plugin name (normalised: lower case, separator runs -> one `-`).
# The docs say only "ignores case and treats any run of separators as one", so edge hyphens are NOT trimmed.
_plugin_name_reserved() {
    local n
    n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g')
    case "$n" in
        claude|anthropic|anthropics|claude-code|claude-mods) echo error; return ;;
        claude-*|anthropic-*|anthropics-*|cc-plugin-*) echo error; return ;;
    esac
    if printf '%s' "$n" | grep -qE '(^|-)official-(claude|anthropic|anthropics)(-|$)|(^|-)(claude|anthropic|anthropics)-official(-|$)'; then echo error; return; fi
    if printf '%s' "$n" | grep -qE '(^|-)(claude|anthropic|anthropics)(-|$)'; then echo warning; fi
}

# Emits plugin-name findings for $1=name $2=display path $3=1 when the plugin-id alphabet applies
# (marketplace entry) $4=true when the name holds a control or bidi character (decided by jq).
_check_plugin_name() {
    local name="$1" where="$2" idrule="${3:-0}" bad="${4:-false}" verdict
    if [ -z "$name" ]; then
        emit_finding 2 "PLUGIN-NAME-FORMAT" "$where" "plugin name is empty"; return
    fi
    if [ "$bad" = true ] || printf '%s' "$name" | grep -qE '[[:space:]@:/\\]'; then
        emit_finding 2 "PLUGIN-NAME-FORMAT" "$where" "plugin name '$name' contains a space, @, :, path separator, control or bidirectional-formatting character — use kebab-case"; return
    fi
    case "$name" in -*)
        emit_finding 2 "PLUGIN-NAME-FORMAT" "$where" "plugin name '$name' starts with '-' (heuristic: claude plugin install would read it as an option)"; return ;;
    esac
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

# $1=name $2=display path $3=true when the name holds a control or bidi character.
_check_marketplace_name() {
    local name="$1" where="$2" bad="${3:-false}" n r canon
    if [ -z "$name" ]; then
        emit_finding 2 "MARKETPLACE-NAME-FORMAT" "$where" "marketplace name is empty"; return
    fi
    if [ "$bad" = true ]; then
        # before the non-ASCII branch: a bidi character is non-ASCII too, but the docs list it as a format error
        emit_finding 2 "MARKETPLACE-NAME-FORMAT" "$where" "marketplace name '$name' contains a control or bidirectional-formatting character — Claude Code cannot install plugins from it"; return
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

# Names are read as `bad<TAB>json-string` so a newline or a control character inside a name cannot split the line.
scan_plugin_names() {
    local pj="$CLAUDE_DIR/.claude-plugin/plugin.json" mp="$CLAUDE_DIR/.claude-plugin/marketplace.json" bad enc
    if [ -f "$pj" ]; then
        while IFS=$'\t' read -r bad enc; do
            _check_plugin_name "$(printf '%s' "$enc" | jq -r .)" ".claude-plugin/plugin.json" 0 "$bad"
        done < <(jq -r 'select(type == "object" and (.name | type == "string")) | .name | "\('"$NAME_BAD_JQ"')\t\(@json)"' "$pj" 2>/dev/null || true)
    fi
    [ -f "$mp" ] || return 0
    while IFS=$'\t' read -r bad enc; do
        _check_marketplace_name "$(printf '%s' "$enc" | jq -r .)" ".claude-plugin/marketplace.json" "$bad"
    done < <(jq -r 'select(type == "object" and (.name | type == "string")) | .name | "\('"$NAME_BAD_JQ"')\t\(@json)"' "$mp" 2>/dev/null || true)
    while IFS=$'\t' read -r bad enc; do
        _check_plugin_name "$(printf '%s' "$enc" | jq -r .)" ".claude-plugin/marketplace.json" 1 "$bad"
    done < <(jq -r 'select(type == "object") | (.plugins // []) | if type == "array" then .[] else empty end | select(type == "object" and (.name | type == "string")) | .name | "\('"$NAME_BAD_JQ"')\t\(@json)"' "$mp" 2>/dev/null || true)
}

# Validate a plugin repo's OWN manifest + structure when CLAUDE_DIR is a plugin
# root (contains .claude-plugin/plugin.json). Phase 2 band; independent of scope —
# lets the tool dogfood on any plugin tree, not just installed user-tree plugins.
scan_plugin_self() {
    local pdir="$CLAUDE_DIR/.claude-plugin" pj comp ver mp src resolved p fld proot rel
    pj="$pdir/plugin.json"
    [ -f "$pj" ] || return 0

    # Component dirs must sit at the plugin root, never inside .claude-plugin/.
    for comp in skills agents commands hooks output-styles monitors workflows themes bin; do
        [ -d "$pdir/$comp" ] \
            && emit_finding 2 "PLUGIN-MISPLACED-DIR" ".claude-plugin/$comp" "component dir '$comp' is inside .claude-plugin/ — it must sit at the plugin root"
    done

    # version is OPTIONAL (docs: omitting it makes Claude Code fall back to the
    # git SHA, which is normal — e.g. marketplace-cataloged plugins carry the
    # version in the catalog). Only flag a version that IS present but not semver.
    ver=$(jq -r '.version // empty' "$pj" 2>/dev/null)
    if [ -n "$ver" ] && ! printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$'; then
        emit_finding 2 "PLUGIN-BAD-VERSION" ".claude-plugin/plugin.json" "version '$ver' is not semantic (expected MAJOR.MINOR.PATCH)"
    fi

    # Declared component paths must be relative and start with ./. The one documented
    # exception is `skills: "."` (the plugin root itself). Inline object values for
    # hooks/mcpServers/lspServers are configuration, not paths — the jq drops them.
    while IFS=$'\t' read -r fld p; do
        [ -z "$p" ] && continue
        case "$p" in
            ./*) continue ;;
            .) [ "$fld" = "skills" ] && continue ;;
        esac
        emit_finding 2 "PLUGIN-ABS-PATH" ".claude-plugin/plugin.json" "$fld path '$p' must be relative and start with ./"
    done < <(jq -r '
        ( to_entries[]
          | select(.key as $k | ["skills","commands","agents","outputStyles","lspServers","workflows","hooks","mcpServers"] | index($k)) ),
        ( (.experimental // {} | if type=="object" then . else {} end) | to_entries[]
          | select(.key as $k | ["themes","monitors"] | index($k))
          | {key: ("experimental." + .key), value: .value} )
        | .key as $k
        | (.value | if type=="array" then .[] elif type=="string" then . else empty end)
        | select(type=="string")
        | "\($k)\t\(.)"' "$pj" 2>/dev/null || true)

    # ${user_config.*} is substituted in skill/agent bodies and in MCP/LSP env blocks,
    # but REJECTED in shell commands and in monitor commands — the hook then runs with
    # the literal, unsubstituted string.
    local where cmd
    while IFS=$'\t' read -r where cmd; do
        [ -z "$cmd" ] && continue
        case "$cmd" in
            *'${user_config.'*)
                emit_finding 2 "PLUGIN-USERCONFIG-IN-SHELL" "$where" "command interpolates \${user_config.…}, which Claude Code rejects in shell commands — use CLAUDE_PLUGIN_OPTION_<KEY> or the exec form with args" ;;
        esac
    done < <(
        _plugin_shell_commands "$pj" ".claude-plugin/plugin.json"
        _plugin_shell_commands "$CLAUDE_DIR/hooks/hooks.json" "hooks/hooks.json"
        _plugin_shell_commands "$CLAUDE_DIR/monitors/monitors.json" "monitors/monitors.json"
    )

    # marketplace.json string sources are LOCAL paths unless they carry a remote scheme
    # (http/git@/npm:/github:/git: — all skipped; object sources are skipped by the jq). A string resolves relative to the marketplace root, optionally under
    # metadata.pluginRoot (which lets an entry omit the ./ prefix). Only flag a local path
    # that resolves to no directory.
    mp="$pdir/marketplace.json"
    if [ -f "$mp" ]; then
        proot=$(jq -r '.metadata.pluginRoot // empty' "$mp" 2>/dev/null)
        while IFS= read -r src; do
            [ -z "$src" ] && continue
            case "$src" in http*|git@*|npm:*|github:*|git:*) continue ;; esac
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
scan_plugin_names
scan_plugin_self
scan_ref_graph
scan_memory
scan_plugin_manifest_keys
scan_output_styles
scan_mcp
scan_mcp_placement

NUM_FINDINGS=$(wc -l <"$TMP_FINDINGS" | tr -d ' ')
META=$(jq -n --arg gen "$GEN_AT" --arg s "$SCOPE" --arg cd "$CLAUDE_DIR" --argjson n "${NUM_FINDINGS:-0}" \
    '{generated_at:$gen, scope:$s, claude_dir:$cd, findings_count:$n, partial:false}')

OUT_TMP="$CACHE_FILE.tmp"
jq -s --argjson meta "$META" '{meta:$meta, findings:.}' "$TMP_FINDINGS" >"$OUT_TMP"
mv -f "$OUT_TMP" "$CACHE_FILE"
cat "$CACHE_FILE"
