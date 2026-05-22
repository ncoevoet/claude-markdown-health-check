#!/usr/bin/env bash
# validate-skills.sh — Deterministic compliance checks for .claude/ ecosystem
# Based on Anthropic's official best practices (verified 2026-04-17):
#   https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
#   https://code.claude.com/docs/en/skills
#   https://code.claude.com/docs/en/memory
#   https://code.claude.com/docs/en/hooks
#   https://code.claude.com/docs/en/settings

set -euo pipefail

# Target a `.claude/`-style directory. Resolution order:
#   1) explicit first positional arg (`validate-skills.sh /path/to/.claude`)
#   2) $CLAUDE_DIR env var
#   3) $HOME/.claude (the canonical user install)
# This avoids the silent "no skills found" trap when the script is invoked from
# an arbitrary CWD with relative paths.
# Optional flag: --listing-cost prints machine-readable budget stats and exits.
# Accepts the flag in any position; the first non-flag positional is CLAUDE_DIR.
LISTING_COST_ONLY=0
POS_ARGS=()
for a in "$@"; do
    case "$a" in
        --listing-cost) LISTING_COST_ONLY=1 ;;
        *) POS_ARGS+=("$a") ;;
    esac
done
CLAUDE_DIR="${POS_ARGS[0]:-${CLAUDE_DIR:-$HOME/.claude}}"
SKILLS_DIR="$CLAUDE_DIR/skills"
COMMANDS_DIR="$CLAUDE_DIR/commands"
# CLAUDE.md is at $CLAUDE_DIR/CLAUDE.md for the user tree (~/.claude/CLAUDE.md),
# but at the project ROOT for a project tree (<proj>/CLAUDE.md — the parent of
# <proj>/.claude). Resolve both so a project CLAUDE.md is not silently skipped.
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
    CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
elif [ -f "$CLAUDE_DIR/../CLAUDE.md" ]; then
    CLAUDE_MD="$CLAUDE_DIR/../CLAUDE.md"
else
    CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
fi
EXIT_CODE=0
ERRORS=0
WARNINGS=0

# Per current docs: description max 1024 chars; description+when_to_use combined
# truncated at 1536 chars in skill listing.
DESC_HARD_MAX=1024
DESC_SOFT_MAX=1536
NAME_MAX=64
SKILL_MAX_LINES=500
SKILL_REF_DIR_THRESHOLD=300
REF_TOC_THRESHOLD=100
CLAUDE_MD_MAX_LINES=200
RESERVED_NAMES=("anthropic" "claude")
# Support/utility directories under skills/ that are not themselves skills.
SKILLS_DIR_EXCLUDES=("bootstrap" "commands")

# Skill listing budget — see https://code.claude.com/docs/en/skills
# "The budget scales dynamically at 1% of the context window, with a fallback of 8,000 characters."
# Override at runtime via SLASH_COMMAND_TOOL_CHAR_BUDGET (env, documented) or
# skillListingBudgetFraction (settings.json, observed in /doctor).
LISTING_BUDGET_FLOOR=8000
LISTING_BUDGET_FRACTION_DEFAULT="0.01"

red()    { printf '\033[0;31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$1"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$1"; }
bold()   { printf '\033[1m%s\033[0m\n' "$1"; }

error()   { red   "[ERROR] $1"; ERRORS=$((ERRORS + 1)); EXIT_CODE=1; }
warning() { yellow "[WARN]  $1"; WARNINGS=$((WARNINGS + 1)); }
ok()      { printf '  [OK]  %s\n' "$1"; }

extract_field() {
    # extract_field <file> <field-name> -> prints raw value (one line)
    local file="$1" field="$2"
    awk -v f="^${field}: *" '
        /^---[[:space:]]*$/ { fm = !fm; next }
        fm && $0 ~ f { sub(f, ""); gsub(/^"|"$/, ""); print; exit }
    ' "$file"
}

validate_skill_md() {
    # Validates a SKILL.md or unified command .md file. Args: <file> <display-name>
    local skill_file="$1" skill_name="$2"
    local lines desc when_to_use combined name name_field
    lines=$(wc -l < "$skill_file")

    # Check: line count (max 500)
    if [ "$lines" -gt "$SKILL_MAX_LINES" ]; then
        error "[OVER-500-LINES] $skill_name: $lines lines (max: $SKILL_MAX_LINES). Split to references/."
    elif [ "$lines" -gt $((SKILL_MAX_LINES - 50)) ]; then
        warning "$skill_name: $lines lines (approaching $SKILL_MAX_LINES limit)"
    fi

    # Check: description length (1024 hard, 1536 combined-with-when_to_use)
    desc=$(extract_field "$skill_file" "description")
    when_to_use=$(extract_field "$skill_file" "when_to_use")
    if [ -n "$desc" ]; then
        local desc_len=${#desc}
        if [ "$desc_len" -gt "$DESC_HARD_MAX" ]; then
            error "[DESCRIPTION-TOO-LONG] $skill_name: description is $desc_len chars (max: $DESC_HARD_MAX)"
        fi
        combined=$((desc_len + ${#when_to_use}))
        if [ "$combined" -gt "$DESC_SOFT_MAX" ]; then
            warning "[DESCRIPTION-TRUNCATED] $skill_name: description + when_to_use = $combined chars (>$DESC_SOFT_MAX truncated in skill listing)"
        fi

        # Check: third-person voice (heuristic). No -i: a case-insensitive
        # \bI\b also matches the "i" in "i.e."/"e.g."; first person is always
        # a capital I. Second-person words stay case-tolerant via [Yy].
        if echo "$desc" | grep -Eq '(\bI\b|\bI'\''ll\b|\bI can\b|\b[Yy]ou can\b|\b[Yy]our\b)'; then
            warning "[THIRD-PERSON] $skill_name: description appears to use first/second person; docs require third person"
        fi
    fi

    # Check: name field validation
    name_field=$(extract_field "$skill_file" "name")
    name="${name_field:-$(basename "$(dirname "$skill_file")")}"
    if [ -n "$name" ]; then
        if ! echo "$name" | grep -Eq '^[a-z0-9-]+$'; then
            error "[BAD-NAME] $skill_name: name '$name' must be lowercase letters, numbers, and hyphens only"
        fi
        if [ "${#name}" -gt "$NAME_MAX" ]; then
            error "[BAD-NAME] $skill_name: name is ${#name} chars (max: $NAME_MAX)"
        fi
        for reserved in "${RESERVED_NAMES[@]}"; do
            if echo "$name" | grep -qi "$reserved"; then
                error "[RESERVED-NAME] $skill_name: name '$name' contains reserved word '$reserved'"
            fi
        done
    fi

    # Check: progressive disclosure for large skills
    local skill_dir
    skill_dir=$(dirname "$skill_file")
    if [ "$lines" -gt "$SKILL_REF_DIR_THRESHOLD" ] && [ ! -d "$skill_dir/references" ]; then
        warning "[NO-PROGRESSIVE-DISCLOSURE] $skill_name: $lines lines with no references/ dir"
    fi

    # Check: every cited references/*.md path resolves on disk (DEAD-REF).
    # Deterministic — must not be left to model judgement. A SKILL.md resolves
    # refs against its own dir; a command file foo.md against the foo/ sibling.
    # Only enforced when a references/ dir exists: a skill WITHOUT one (e.g.
    # skill-creator) mentions references/*.md paths only as illustrative
    # examples, not as real progressive-disclosure links.
    local ref_base ref
    if [ "$(basename "$skill_file")" = "SKILL.md" ]; then
        ref_base="$skill_dir"
    else
        ref_base="${skill_file%.md}"
    fi
    if [ -d "$ref_base/references" ]; then
        while IFS= read -r ref; do
            [ -z "$ref" ] && continue
            if [ ! -f "$ref_base/$ref" ]; then
                error "[DEAD-REF] $skill_name: cites $ref — missing at $ref_base/$ref"
            fi
        done < <(awk '{
            s = $0; gsub(/[^A-Za-z0-9._\/-]/, " ", s); n = split(s, a, " ")
            for (i = 1; i <= n; i++)
                if (a[i] ~ /^references\/[A-Za-z0-9._\/-]+\.md$/) print a[i]
        }' "$skill_file" 2>/dev/null | sort -u || true)
    fi
}

# Detect duplicate keys inside a single JSON object. jq silently keeps only the
# last value of a duplicated key, so a char-level scan is required: track brace
# depth (ignoring braces inside strings) and flag any key seen twice within the
# same object instance.
check_json_duplicate_keys() {
    local json_file="$1" display="$2" dups k
    [ -f "$json_file" ] || return 0
    dups=$(awk '
        BEGIN { depth = 0; in_str = 0; esc = 0; pending = ""; cur = "" }
        {
            L = length($0)
            for (i = 1; i <= L; i++) {
                c = substr($0, i, 1)
                if (in_str) {
                    if (esc)       { esc = 0; cur = cur c; continue }
                    if (c == "\\") { esc = 1; cur = cur c; continue }
                    if (c == "\"") { in_str = 0; pending = cur; continue }
                    cur = cur c; continue
                }
                if (c == "\"") { in_str = 1; cur = ""; continue }
                if (c == "{")  { depth++; objseq[depth]++; pending = ""; continue }
                if (c == "}")  { if (depth > 0) depth--; pending = ""; continue }
                if (c == ":") {
                    if (pending != "") {
                        k = depth SUBSEP objseq[depth] SUBSEP pending
                        if (k in seen) print pending; else seen[k] = 1
                        pending = ""
                    }
                    continue
                }
                if (c == " " || c == "\t" || c == "\r") continue
                pending = ""
            }
        }
    ' "$json_file" 2>/dev/null | sort -u || true)
    if [ -n "$dups" ]; then
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            error "[DUPLICATE-KEY] $display: key \"$k\" defined more than once in the same object"
        done <<< "$dups"
    fi
}

# Sum description + when_to_use chars across every SKILL.md and command .md
# under CLAUDE_DIR. Mirrors what Claude Code feeds into the skill-listing block.
compute_listing_cost() {
    local total=0 count=0 desc when_to_use entry_chars
    _accumulate() {
        local f="$1"
        [ -f "$f" ] || return 0
        desc=$(extract_field "$f" "description")
        when_to_use=$(extract_field "$f" "when_to_use")
        entry_chars=$(( ${#desc} + ${#when_to_use} ))
        # Per-entry hard cap at 1536 — anything past that never reaches Claude.
        [ "$entry_chars" -gt "$DESC_SOFT_MAX" ] && entry_chars=$DESC_SOFT_MAX
        total=$(( total + entry_chars ))
        count=$(( count + 1 ))
    }
    if [ -d "$SKILLS_DIR" ]; then
        for d in "$SKILLS_DIR"/*/; do
            [ -d "$d" ] || continue
            local n
            n=$(basename "$d")
            local skip=0
            for ex in "${SKILLS_DIR_EXCLUDES[@]}"; do
                [ "$n" = "$ex" ] && skip=1 && break
            done
            [ "$skip" = 1 ] && continue
            _accumulate "$d/SKILL.md"
        done
    fi
    if [ -d "$COMMANDS_DIR" ]; then
        for f in "$COMMANDS_DIR"/*.md; do
            _accumulate "$f"
        done
    fi
    printf '%d %d\n' "$total" "$count"
}

# --listing-cost: print "total_chars count effective_budget over" and exit.
# Resolution order for the budget (most specific wins):
#   1. SLASH_COMMAND_TOOL_CHAR_BUDGET env var (documented hard override).
#   2. settings.json `skillListingBudgetFraction` × CLAUDE_CONTEXT_TOKENS × 4.
#   3. LISTING_BUDGET_FRACTION_DEFAULT (0.01) × CLAUDE_CONTEXT_TOKENS × 4.
# CLAUDE_CONTEXT_TOKENS defaults to 200000 (Sonnet/Haiku worst case); set it
# to 1000000 for Opus 1M sessions to avoid under-flagging budget overflows.
if [ "$LISTING_COST_ONLY" = 1 ]; then
    read -r LIST_TOTAL LIST_COUNT < <(compute_listing_cost)
    CONTEXT_TOKENS="${CLAUDE_CONTEXT_TOKENS:-200000}"
    if [ -n "${SLASH_COMMAND_TOOL_CHAR_BUDGET:-}" ]; then
        EFFECTIVE_BUDGET="$SLASH_COMMAND_TOOL_CHAR_BUDGET"
    else
        FRACTION="$LISTING_BUDGET_FRACTION_DEFAULT"
        SETTINGS_JSON="$CLAUDE_DIR/settings.json"
        if [ -f "$SETTINGS_JSON" ] && command -v jq >/dev/null 2>&1; then
            v=$(jq -r '.skillListingBudgetFraction // empty' "$SETTINGS_JSON" 2>/dev/null)
            [ -n "$v" ] && FRACTION="$v"
        fi
        EFFECTIVE_BUDGET=$(awk -v f="$FRACTION" -v c="$CONTEXT_TOKENS" -v floor="$LISTING_BUDGET_FLOOR" \
            'BEGIN{ b = c * 4 * f; if (b < floor) b = floor; printf "%d", b }')
    fi
    OVER=$(( LIST_TOTAL - EFFECTIVE_BUDGET ))
    printf '%d %d %d %d\n' "$LIST_TOTAL" "$LIST_COUNT" "$EFFECTIVE_BUDGET" "$OVER"
    exit 0
fi

bold "=== .claude/ Ecosystem Compliance Validator ==="
echo "Target: $CLAUDE_DIR"
echo ""

# --- Check 1: CLAUDE.md line count ---
bold "--- CLAUDE.md ---"
if [ -f "$CLAUDE_MD" ]; then
    lines=$(wc -l < "$CLAUDE_MD")
    if [ "$lines" -gt "$CLAUDE_MD_MAX_LINES" ]; then
        error "CLAUDE.md is $lines lines (target: <$CLAUDE_MD_MAX_LINES). Loaded every turn — trim or use imports."
    else
        ok "CLAUDE.md: $lines lines (under $CLAUDE_MD_MAX_LINES)"
    fi
else
    warning "No CLAUDE.md found"
fi
echo ""

# --- Check 2: Skills (SKILL.md files) ---
bold "--- Skills ---"
if [ ! -d "$SKILLS_DIR" ]; then
    warning "No $SKILLS_DIR directory found"
else
    for skill_dir in "$SKILLS_DIR"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        skip=0
        for ex in "${SKILLS_DIR_EXCLUDES[@]}"; do
            [ "$skill_name" = "$ex" ] && skip=1 && break
        done
        [ "$skip" = 1 ] && continue
        skill_file="$skill_dir/SKILL.md"
        if [ ! -f "$skill_file" ]; then
            warning "$skill_name: No SKILL.md found"
            continue
        fi
        validate_skill_md "$skill_file" "$skill_name/SKILL.md"
    done
fi
echo ""

# --- Check 3: Commands (unified with skills per current docs) ---
bold "--- Commands ---"
if [ -d "$COMMANDS_DIR" ]; then
    for cmd_file in "$COMMANDS_DIR"/*.md; do
        [ -f "$cmd_file" ] || continue
        validate_skill_md "$cmd_file" "commands/$(basename "$cmd_file")"
    done
else
    ok "No $COMMANDS_DIR directory (skipped)"
fi
echo ""

# --- Check 4: Reference files ---
bold "--- Reference Files ---"
for ref_file in "$SKILLS_DIR"/*/references/*.md; do
    [ -f "$ref_file" ] || continue
    ref_lines=$(wc -l < "$ref_file")
    ref_name=${ref_file#$SKILLS_DIR/}
    skill_name=$(basename "$(dirname "$(dirname "$ref_file")")")

    if [ "$ref_lines" -gt "$REF_TOC_THRESHOLD" ]; then
        if ! grep -qiE '^##[[:space:]]+(Table of Contents|Contents)' "$ref_file" 2>/dev/null; then
            error "[MISSING-TOC] $ref_name: $ref_lines lines with no Table of Contents"
        fi
    fi

    # Allow refs to the skill's own data dir (`.claude/<skill_name>/...`),
    # its sibling config files (`.claude/<skill_name>.json`, etc.), and the
    # conventional shared output dir `.claude/reports/` — these are
    # consumer-project paths the skill creates/owns, not foreign cross-refs.
    chained=$(grep -n '\.claude/' "$ref_file" 2>/dev/null \
              | grep -Ev "\.claude/(${skill_name}(/|\.[a-zA-Z0-9]+)|reports[/'\"\` ]?)" | head -3 || true)
    if [ -n "$chained" ]; then
        error "[CHAINED-REF] $ref_name links to external .claude/ path (allowed: .claude/$skill_name/ or .claude/$skill_name.*)"
        echo "    $chained" | head -2
    fi
done

# Command-support reference trees (e.g. ~/.claude/review-all/references/).
# Installed at a fixed absolute path, so they may legitimately reference
# their own .claude/<subtree>/... paths. Flag .claude/ refs to *other*
# subtrees as CHAINED-REF.
sub_refs_count=0
for sub_refs in "$CLAUDE_DIR"/*/references; do
    [ -d "$sub_refs" ] || continue
    sub=$(basename "$(dirname "$sub_refs")")
    [ "$sub" = "skills" ] && continue
    for ref_file in "$sub_refs"/*.md; do
        [ -f "$ref_file" ] || continue
        sub_refs_count=$((sub_refs_count + 1))
        ref_lines=$(wc -l < "$ref_file")
        ref_name=${ref_file#$CLAUDE_DIR/}

        if [ "$ref_lines" -gt "$REF_TOC_THRESHOLD" ]; then
            if ! grep -qiE '^##[[:space:]]+(Table of Contents|Contents)' "$ref_file" 2>/dev/null; then
                error "[MISSING-TOC] $ref_name: $ref_lines lines with no Table of Contents"
            fi
        fi

        # Allow refs to the subtree itself (`.claude/<sub>/...`) and to its
        # sibling config files (`.claude/<sub>.json`, `.claude/<sub>.md`, etc.).
        chained=$(grep -n '\.claude/' "$ref_file" 2>/dev/null \
                  | grep -Ev "\.claude/${sub}(/|\.[a-zA-Z0-9]+)" | head -3 || true)
        if [ -n "$chained" ]; then
            error "[CHAINED-REF] $ref_name links to external .claude/ path (allowed: .claude/$sub/ or .claude/$sub.*)"
            echo "    $chained" | head -2
        fi
    done
done
echo ""

# --- Check 5: settings.json duplicate keys ---
bold "--- Settings ---"
settings_checked=0
for settings_file in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
    [ -f "$settings_file" ] || continue
    settings_checked=$((settings_checked + 1))
    check_json_duplicate_keys "$settings_file" "$(basename "$settings_file")"
done
if [ "$settings_checked" -eq 0 ]; then
    ok "No settings.json found (skipped)"
fi
echo ""

# --- Summary ---
bold "=== Summary ==="
# `-L` so symlinked skills (per sync-skills.sh) are counted as dirs and the
# walker descends into them to find references/.
total_skills=$( { find -L "$SKILLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true; } | wc -l)
total_cmds=$(   { find    "$COMMANDS_DIR" -maxdepth 1 -name '*.md' 2>/dev/null      || true; } | wc -l)
total_refs=$(   { find -L "$SKILLS_DIR" -path '*/references/*.md' 2>/dev/null       || true; } | wc -l)
total_refs=$((total_refs + sub_refs_count))
echo "  Skills checked:           $total_skills"
echo "  Commands checked:         $total_cmds"
echo "  Reference files checked:  $total_refs"
echo "  Settings files checked:   $settings_checked"
if [ -f "$CLAUDE_MD" ]; then
    echo "  CLAUDE.md lines:          $(wc -l < "$CLAUDE_MD")"
else
    echo "  CLAUDE.md lines:          N/A"
fi

if [ "$ERRORS" -gt 0 ]; then
    red "  Errors:   $ERRORS"
fi
if [ "$WARNINGS" -gt 0 ]; then
    yellow "  Warnings: $WARNINGS"
fi
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    green "  All checks passed!"
fi

exit $EXIT_CODE
