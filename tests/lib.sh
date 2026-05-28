#!/usr/bin/env bash
# lib.sh — shared assertions + tag extraction for the deterministic test suite.
#
# The scanners' output formats are the contract under test, so the parsing lives
# in ONE place: if validate-skills.sh / scan-graph.sh change their output shape,
# update only this file.
#
#   validate-skills.sh : ANSI-wrapped lines `\033[..m[ERROR] [TAG] loc: msg\033[0m`
#                        and `[WARN]  [TAG] loc: msg` (two spaces after WARN).
#                        The canonical tag is the SECOND bracket group. Untagged
#                        lines (`[WARN]  No CLAUDE.md found`, `[OK] ...`) are dropped.
#   scan-graph.sh      : JSON on stdout; tags at `.findings[].tag`.

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }

# stdin: raw validate-skills.sh output -> one canonical TAG per line (unsorted).
extract_validator_tags() {
    strip_ansi \
        | grep -E '^\[(ERROR|WARN)\][[:space:]]+\[[A-Z0-9-]+\]' \
        | sed -E 's/^\[(ERROR|WARN)\][[:space:]]+\[([A-Z0-9-]+)\].*/\2/' \
        | grep -E '^[A-Z0-9-]+$'
}

# stdin: scan-graph.sh JSON -> one TAG per finding (unsorted).
extract_graph_tags() { jq -r '.findings[]?.tag' 2>/dev/null; }

# stdin: raw validate-skills.sh output -> normalized finding lines `[TAG] loc: msg`
# (ERROR/WARN prefix removed) so locator substrings can be grepped per tag.
normalize_validator_findings() {
    strip_ansi \
        | grep -E '^\[(ERROR|WARN)\][[:space:]]+\[[A-Z0-9-]+\]' \
        | sed -E 's/^\[(ERROR|WARN)\][[:space:]]+//'
}

# stdin: scan-graph.sh JSON -> normalized finding lines `[TAG] path :: msg`.
normalize_graph_findings() {
    jq -r '.findings[]? | "[\(.tag)] \(.path) :: \(.message)"' 2>/dev/null
}

# assert_tag_present <tagset-multiline> <tag> <label>
assert_tag_present() {
    if grep -qx "$2" <<<"$1"; then ok "$3"
    else no "$3"; printf '       tag %s absent; got: {%s}\n' "$2" "$(tr '\n' ' ' <<<"$1" | sed 's/  */ /g;s/^ //;s/ $//')"; fi
}

# assert_tag_absent <tagset-multiline> <tag> <label>
assert_tag_absent() {
    if grep -qx "$2" <<<"$1"; then no "$3"; printf '       tag %s should be absent (false positive)\n' "$2"
    else ok "$3"; fi
}

# assert_finding_at <findings-multiline> <tag> <path-substring> <label>
# passes when some normalized finding line carries BOTH [TAG] and the substring.
assert_finding_at() {
    if grep -F "[$2]" <<<"$1" | grep -qF "$3"; then ok "$4"
    else no "$4"; printf '       no [%s] finding mentioning "%s"\n' "$2" "$3"; fi
}

# assert_empty_tagset <tagset-multiline> <label>
assert_empty_tagset() {
    local nonempty; nonempty=$(grep -cE '^[A-Z0-9-]+$' <<<"$1" || true)
    if [ "${nonempty:-0}" -eq 0 ]; then ok "$2"
    else no "$2"; printf '       expected zero findings; got: {%s}\n' "$(tr '\n' ' ' <<<"$1" | sed 's/  */ /g;s/^ //;s/ $//')"; fi
}
