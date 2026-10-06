#!/usr/bin/env bash
# check-tag-registration.sh — every tag a deterministic script can emit must be registered in the docs.
#
# Emitted tags are read from the scripts themselves (not from a hand-kept list):
#   validate-skills.sh : `error "[TAG] ..."` / `warning "[TAG] ..."` calls
#   scan-graph.sh      : `emit_finding <phase> "TAG" ...` calls
# Rule: each emitted tag appears, backticked, in
#   commands/markdown-health-check.md   (the `## Tag Set` tier lists only)
#   references/report-format.md         (the `### Tag → domain map` only)
#   references/finding-verification.md  (anywhere: fast-path lists) — except tags in tests/judgment-tags.txt
# tests/judgment-tags.txt: one tag per line, blank lines and `#` lines ignored; a tag there is emitted
# by a script but deliberately verified rather than fast-pathed. The gate also fails on a stale entry.
#
# Env (so the gate can target a damaged copy or an older tree):
#   MHC_SCRIPTS_DIR  default <repo>/plugin/commands/scripts
#   MHC_DOCS_DIR     default <repo>/plugin
#   MHC_JUDGMENT     default <repo>/tests/judgment-tags.txt
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPTS="${MHC_SCRIPTS_DIR:-$REPO/plugin/commands/scripts}"
DOCS="${MHC_DOCS_DIR:-$REPO/plugin}"
JUDGMENT="${MHC_JUDGMENT:-$HERE/judgment-tags.txt}"
rc=0

validator_tags() {
    grep -E '(error|warning)[[:space:]]+"\[[A-Z]' "$SCRIPTS/validate-skills.sh" \
        | grep -ohE '"\[[A-Z][A-Z0-9-]+\]' | tr -d '"[]'
}
graph_tags() {
    grep -ohE 'emit_finding +[0-9]+ +"[A-Z][A-Z0-9-]+"' "$SCRIPTS/scan-graph.sh" \
        | grep -oE '"[A-Z0-9-]+"' | tr -d '"'
}

EMITTED=$({ validator_tags; graph_tags; } | sort -u)
JUDG=$(grep -vE '^[[:space:]]*(#|$)' "$JUDGMENT" 2>/dev/null | tr -d '[:blank:]' | sort -u)

if [ -z "$EMITTED" ]; then
    echo "FAIL no emitted tags extracted from $SCRIPTS (extractor broken?)"
    exit 1
fi

# Print the part of a doc that must hold the registration: a bounded section, or the whole file.
section() {
    case "$1" in
        commands/markdown-health-check.md) sed -n '/^## Tag Set/,/^## Output Rules/p' "$2" ;;
        references/report-format.md) sed -n '/^### Tag → domain map/,/^Audit-meta/p' "$2" ;;
        *) cat "$2" ;;
    esac
}

for rel in commands/markdown-health-check.md references/report-format.md references/finding-verification.md; do
    f="$DOCS/$rel"
    [ -f "$f" ] || { echo "FAIL missing doc $f"; rc=1; continue; }
    body=$(section "$rel" "$f")
    if [ -z "$body" ]; then echo "FAIL section for $rel not found (heading renamed?)"; rc=1; continue; fi
    for t in $EMITTED; do
        if [ "$rel" = references/finding-verification.md ] && printf '%s\n' "$JUDG" | grep -qxF "$t"; then
            continue
        fi
        printf '%s\n' "$body" | grep -qF "\`$t\`" || { echo "MISSING $t in $(basename "$f")"; rc=1; }
    done
done

for t in $JUDG; do
    printf '%s\n' "$EMITTED" | grep -qxF "$t" || { echo "STALE $t in judgment-tags.txt (no script emits it)"; rc=1; }
done

if [ "$rc" -eq 0 ]; then
    echo "  ok   all $(printf '%s\n' "$EMITTED" | wc -l | tr -d ' ') emitted tags registered in the command file, report-format.md and finding-verification.md"
fi
exit "$rc"
