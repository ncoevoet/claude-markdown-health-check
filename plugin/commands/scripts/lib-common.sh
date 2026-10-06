#!/usr/bin/env bash
# lib-common.sh — helpers shared by validate-skills.sh and scan-graph.sh. Sourced, never run:
# it sets no shell options and prints nothing. It ships beside the scripts (make install and
# the plugin tree copy the whole scripts/ directory), so `. "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"`
# resolves from the plugin dir, from ~/.claude/commands/scripts/, and under run-evals-headless.sh.

# Lexical path normalisation, pure bash (realpath/readlink -m are not portable to macOS); the
# filesystem is never touched. Splits on /, skips "" and "." segments, ".." pops one.
# Prints "/a/b" ("" = the root itself). With $2 = strict, returns 1 when a RELATIVE path
# has a ".." that climbs above its start; an absolute path never fails (extra ".." stop at /).
_mhc_lexnorm() {
    local p="$1" mode="${2:-}" rest seg s=""
    rest="$p/"
    while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        rest="${rest#*/}"
        case "$seg" in
            ""|.) ;;
            ..)
                if [ -n "$s" ]; then s="${s%/*}"
                elif [ "$mode" = strict ]; then case "$p" in /*) ;; *) return 1 ;; esac
                fi ;;
            *) s="$s/$seg" ;;
        esac
    done
    printf '%s' "$s"
}

# Absolute lexical normalisation: always prints a "/"-rooted path ("/" for the root).
_mhc_lexpath() {
    local s
    s=$(_mhc_lexnorm "$1")
    printf '%s\n' "${s:-/}"
}

# Lexically normalise a manifest component path against the plugin root. $2 is the physical
# plugin root. Prints the root-relative form ("" = the root itself, no leading ./ or trailing /)
# and returns 1 when the path leaves the root: a `..` that climbs above it, or an absolute
# path outside it. A `..` that stays inside the root is fine here.
_plugin_path_norm() {
    local p="$1" root="$2" s
    s=$(_mhc_lexnorm "$p" strict) || return 1
    case "$p" in
        /*)
            if [ "$s" = "$root" ]; then s=""
            else case "$s" in "$root"/*) s="${s#"$root"/}" ;; *) return 1 ;; esac
            fi
            printf '%s' "$s" ;;
        *) printf '%s' "${s#/}" ;;
    esac
}

# Manifest entries (string or array) of <key> in <plugin-root>/.claude-plugin/plugin.json, relative
# and inside the plugin: "./x" -> x, "." -> "." ; absolute or ".." entries are skipped
# (PLUGIN-PATH-ESCAPE territory). Args: <plugin-root> <key>
_plugin_manifest_entries() {
    local manifest="$1/.claude-plugin/plugin.json" e
    [ -f "$manifest" ] || return 0
    while IFS= read -r e; do
        e="${e#./}"
        e="${e%/}"
        case "$e" in
            /*|..|../*|*/..|*/../*) continue ;;
            "") e="." ;;
        esac
        printf '%s\n' "$e"
    done < <(jq -r --arg k "$2" '(.[$k] // empty) | if type == "string" then [.] elif type == "array" then . else [] end | .[] | strings' "$manifest" 2>/dev/null || true)
    return 0
}

# Succeeds when the two paths resolve to the same physical location (readlink -f; an unresolvable
# path resolves to the empty string, as in the inline tests this replaces).
_mhc_same_path() {
    [ "$(readlink -f "$1" 2>/dev/null)" = "$(readlink -f "$2" 2>/dev/null)" ]
}
