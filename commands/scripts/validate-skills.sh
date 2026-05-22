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
# Auto-memory index budget (loaded slice) and hook-timeout defaults (seconds).
MEMORY_MAX_LINES=200
MEMORY_MAX_BYTES=25600
HOOK_TIMEOUT_COMMAND=600
HOOK_TIMEOUT_PROMPT=30
HOOK_TIMEOUT_AGENT=60

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
    # extract_field <file> <field-name> -> prints the value. Joins a multi-line
    # YAML block scalar / wrapped value with spaces; prints "" when absent.
    local file="$1" field="$2"
    awk -v key="$field" '
        /^---[[:space:]]*$/ { if (infm) { if (cap) print val; exit } infm = 1; next }
        !infm { next }
        cap {
            if ($0 ~ /^[[:space:]]/) {
                line = $0; sub(/^[[:space:]]+/, "", line)
                val = (val == "" ? line : val " " line); next
            }
            print val; exit
        }
        index($0, key ":") == 1 {
            v = substr($0, length(key) + 2)
            sub(/^[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            gsub(/^"|"$/, "", v)
            if (v == "" || v == "|" || v == ">" || v == "|-" || v == ">-" || v == "|+" || v == ">+") {
                cap = 1; val = ""; next
            }
            print v; exit
        }
    ' "$file"
}

validate_skill_md() {
    # Validates a SKILL.md or unified command .md file. Args: <file> <display-name>
    local skill_file="$1" skill_name="$2"
    local lines desc when_to_use combined name name_field skill_dir dir_name is_skill_md
    skill_dir=$(dirname "$skill_file")
    dir_name=$(basename "$skill_dir")
    [ "$(basename "$skill_file")" = "SKILL.md" ] && is_skill_md=1 || is_skill_md=0
    lines=$(wc -l < "$skill_file")

    # Check: line count (max 500)
    if [ "$lines" -gt "$SKILL_MAX_LINES" ]; then
        error "[OVER-500-LINES] $skill_name: $lines lines (max: $SKILL_MAX_LINES). Split to references/."
    elif [ "$lines" -gt $((SKILL_MAX_LINES - 50)) ]; then
        warning "$skill_name: $lines lines (approaching $SKILL_MAX_LINES limit)"
    fi

    # Check: description present, then length (1024 hard, 1536 combined)
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
    elif [ "$is_skill_md" = 1 ]; then
        error "[MISSING-DESC] $skill_name: no 'description' in frontmatter (required — without it the skill cannot be auto-routed)"
    fi

    # Check: name field — charset, length, reserved words
    name_field=$(extract_field "$skill_file" "name")
    if [ "$is_skill_md" = 1 ]; then
        name="${name_field:-$dir_name}"
    else
        name="${name_field:-$(basename "$skill_file" .md)}"
    fi
    if [ -n "$name" ]; then
        if ! echo "$name" | grep -Eq '^[a-z0-9-]+$'; then
            error "[BAD-NAME] $skill_name: name '$name' must be lowercase letters, numbers, and hyphens only"
        fi
        if [ "${#name}" -gt "$NAME_MAX" ]; then
            error "[BAD-NAME] $skill_name: name is ${#name} chars (max: $NAME_MAX)"
        fi
        if [ "$is_skill_md" = 1 ]; then
            for reserved in "${RESERVED_NAMES[@]}"; do
                case "$name" in
                    *"$reserved"*)
                        error "[RESERVED-NAME] $skill_name: name '$name' contains reserved word '$reserved' (a skill name may not contain it)"
                        ;;
                esac
            done
        fi
    fi
    # Check: a SKILL.md frontmatter name must match its directory name
    if [ "$is_skill_md" = 1 ] && [ -n "$name_field" ] && [ "$name_field" != "$dir_name" ]; then
        warning "[NAME-MISMATCH] $skill_name: frontmatter name '$name_field' != directory '$dir_name'"
    fi

    # Check: progressive disclosure for large SKILL.md files. Command files keep
    # their references at a non-standard install path, so skip them here — the
    # OVER-500-LINES / approaching-limit checks still cover oversized commands.
    if [ "$is_skill_md" = 1 ] && [ "$lines" -gt "$SKILL_REF_DIR_THRESHOLD" ] && [ ! -d "$skill_dir/references" ]; then
        warning "[NO-PROGRESSIVE-DISCLOSURE] $skill_name: $lines lines with no references/ dir"
    fi

    # Check: every cited references/*.md path resolves on disk (DEAD-REF).
    # Deterministic — must not be left to model judgement. A SKILL.md resolves
    # refs against its own dir; a command file foo.md against the foo/ sibling.
    # Only enforced when a references/ dir exists: a skill WITHOUT one (e.g.
    # skill-creator) mentions references/*.md paths only as illustrative
    # examples, not as real progressive-disclosure links.
    local ref_base ref
    if [ "$is_skill_md" = 1 ]; then
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

# Detect duplicate string entries within any array of a JSON file (e.g. the
# same Bash(...) permission listed twice in preApprovedTools.bash, or a guide
# repeated in an automatic-guide-triggers list). Harmless at runtime but a
# careless-edit smell — same family as duplicate keys. Needs jq; skips without.
check_json_duplicate_entries() {
    local json_file="$1" display="$2" dups line
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    dups=$(jq -r '
        paths(arrays) as $p
        | (getpath($p) | map(select(type == "string"))) as $a
        | ($a | group_by(.) | map(select(length > 1)) | map(.[0])) as $d
        | select(($d | length) > 0)
        | "\($p | map(tostring) | join(".")) :: \($d | join(", "))"
    ' "$json_file" 2>/dev/null || true)
    if [ -n "$dups" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            warning "[DUPLICATE-ENTRY] $display: array ${line%% :: *} repeats: ${line#* :: }"
        done <<< "$dups"
    fi
}

# Verify a JSON file parses. A malformed settings.json is silently ignored by
# Claude Code, so this gates the other settings checks (they assume valid JSON).
check_json_valid() {
    local json_file="$1" display="$2" err
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    if ! err=$(jq empty "$json_file" 2>&1); then
        error "[INVALID-JSON] $display: not valid JSON (Claude Code ignores the whole file) — $(printf '%s' "$err" | head -1)"
        return 1
    fi
    return 0
}

# Resolve a ".claude/<rest>" or "~/.claude/<rest>" reference to its on-disk path.
# A bare .claude/ is scope-relative ($CLAUDE_DIR); a ~/.claude/ is the user tree.
_resolve_dotclaude() {
    case "$1" in
        "~/.claude/"*) printf '%s/%s\n' "$HOME/.claude" "${1#\~/.claude/}" ;;
        ".claude/"*)   printf '%s/%s\n' "$CLAUDE_DIR"   "${1#.claude/}" ;;
        *)             printf '%s/%s\n' "$CLAUDE_DIR"   "$1" ;;
    esac
}

# Flag .claude/*.{md,sh,json} (and ~/.claude/...) paths in a text file that do
# not resolve. The ~/ form points at the user tree, a bare .claude/ at the scope.
check_dead_refs_in_file() {
    local src="$1" display="$2" p
    [ -f "$src" ] || return 0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -f "$(_resolve_dotclaude "$p")" ] || error "[DEAD-REF] $display: references $p — missing on disk"
    done < <(grep -oE '(~/)?\.claude/[A-Za-z0-9._/-]+\.(md|sh|json)' "$src" 2>/dev/null | sort -u || true)
}

# Flag settings.json `guides` paths that do not resolve on disk.
check_settings_guide_refs() {
    local json_file="$1" display="$2" p
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -f "$(_resolve_dotclaude "$p")" ] || error "[DEAD-REF] $display: guides path $p — missing on disk"
    done < <(jq -r '.guides? // {} | [.. | strings] | .[]' "$json_file" 2>/dev/null | sort -u || true)
}

# Flag MCP servers defined in mcpServers but absent from preApprovedTools.
check_mcp_preapproved() {
    local json_file="$1" display="$2" srv
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS= read -r srv; do
        [ -z "$srv" ] && continue
        if ! jq -e --arg s "$srv" '
            (.preApprovedTools // {}) as $p
            | (.permissions.allow // []) as $allow
            | ($p | has($s))
              or ([$p[]? | arrays | .[]] | any(type == "string" and test("mcp__\($s)__")))
              or ($allow | any(type == "string" and test("mcp__\($s)__")))
        ' "$json_file" >/dev/null 2>&1; then
            error "[MISSING-PRE-APPROVED] $display: MCP server \"$srv\" not in preApprovedTools or permissions.allow"
        fi
    done < <(jq -r '.mcpServers? // {} | keys[]' "$json_file" 2>/dev/null || true)
}

# Flag hook scripts on disk that no settings file registers. pre-commit.sh and
# check-signals.sh are conventional standalone hooks — never flagged.
check_unregistered_hooks() {
    local hooks_dir="$CLAUDE_DIR/hooks" h base s found
    [ -d "$hooks_dir" ] || return 0
    for h in "$hooks_dir"/*.sh; do
        [ -f "$h" ] || continue
        base=$(basename "$h")
        case "$base" in pre-commit.sh|check-signals.sh) continue ;; esac
        found=0
        for s in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json" "$hooks_dir/hooks.json"; do
            [ -f "$s" ] || continue
            if grep -qF "$base" "$s" 2>/dev/null; then found=1; break; fi
        done
        if [ "$found" = 0 ]; then
            warning "[UNREGISTERED-HOOK] $base: in hooks/ but referenced by no settings.json (hooks or statusLine)"
        fi
    done
}

# Flag auto-memory MEMORY.md index files over the loaded-slice budget.
check_memory_overflow() {
    local mem ls bs
    for mem in "$CLAUDE_DIR"/projects/*/memory/MEMORY.md; do
        [ -f "$mem" ] || continue
        ls=$(wc -l < "$mem"); bs=$(wc -c < "$mem")
        if [ "$ls" -gt "$MEMORY_MAX_LINES" ] || [ "$bs" -gt "$MEMORY_MAX_BYTES" ]; then
            error "[MEMORY-OVERFLOW] ${mem#$CLAUDE_DIR/}: $ls lines / $bs bytes (max $MEMORY_MAX_LINES lines / $MEMORY_MAX_BYTES bytes)"
        fi
    done
}

# Flag hook timeouts above 2x the documented per-type default. Defaults:
# command/http/mcp_tool 600s, prompt 30s, agent 60s — but a command hook under
# a UserPromptSubmit event defaults to 30s.
check_hook_timeouts() {
    local json_file="$1" display="$2" ev typ t def
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r ev typ t; do
        case "${t:-}" in ''|*[!0-9]*) continue ;; esac
        case "$typ" in
            command|http|mcp_tool) def=$HOOK_TIMEOUT_COMMAND ;;
            prompt)                def=$HOOK_TIMEOUT_PROMPT ;;
            agent)                 def=$HOOK_TIMEOUT_AGENT ;;
            *) continue ;;
        esac
        if [ "$typ" = "command" ] && [ "$ev" = "UserPromptSubmit" ]; then
            def=$HOOK_TIMEOUT_PROMPT
        fi
        if [ "$t" -gt $((def * 2)) ]; then
            warning "[SUSPICIOUS-TIMEOUT] $display: a $typ hook ($ev) has timeout ${t}s (>2x the ${def}s default)"
        fi
    done < <(jq -r '.hooks // {} | to_entries[] | .key as $ev | .value[]? | .hooks[]? | select(has("type") and has("timeout")) | "\($ev)\t\(.type)\t\(.timeout)"' "$json_file" 2>/dev/null || true)
}

# Audit .claude/rules/ path-scoped rule files. A rule with a `paths:` key that
# lists no glob is a silent bug (it then loads unconditionally); a large rule
# with no `paths:` scope loads into every session and costs tokens.
check_rules() {
    local rules_dir="$CLAUDE_DIR/rules" rf rel pf lc has_paths
    [ -d "$rules_dir" ] || return 0
    while IFS= read -r rf; do
        [ -f "$rf" ] || continue
        rel=${rf#$CLAUDE_DIR/}
        lc=$(wc -l < "$rf")
        pf=$(extract_field "$rf" "paths")
        if grep -qE '^paths:' "$rf" 2>/dev/null; then has_paths=1; else has_paths=0; fi
        if [ "$has_paths" = 1 ] && [ -z "$pf" ]; then
            warning "[BAD-RULE-FRONTMATTER] $rel: 'paths:' declared but lists no glob"
        elif [ "$has_paths" = 0 ] && [ "$lc" -gt "$CLAUDE_MD_MAX_LINES" ]; then
            warning "[RULE-OVERSIZED] $rel: $lc lines, no 'paths:' scope — loaded into every session"
        fi
    done < <(find -L "$rules_dir" -name '*.md' -type f 2>/dev/null || true)
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
    # settings.json maxSkillDescriptionChars overrides the per-entry cap.
    if [ -f "$CLAUDE_DIR/settings.json" ] && command -v jq >/dev/null 2>&1; then
        msdc=$(jq -r '.maxSkillDescriptionChars // empty' "$CLAUDE_DIR/settings.json" 2>/dev/null)
        case "$msdc" in ''|*[!0-9]*) ;; *) DESC_SOFT_MAX=$msdc ;; esac
    fi
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

# --- Check 1: CLAUDE.md (line count + dead .claude/ references) ---
bold "--- CLAUDE.md ---"
if [ -f "$CLAUDE_MD" ]; then
    lines=$(wc -l < "$CLAUDE_MD")
    if [ "$lines" -gt "$CLAUDE_MD_MAX_LINES" ]; then
        error "CLAUDE.md is $lines lines (target: <$CLAUDE_MD_MAX_LINES). Loaded every turn — trim or use imports."
    else
        ok "CLAUDE.md: $lines lines (under $CLAUDE_MD_MAX_LINES)"
    fi
    check_dead_refs_in_file "$CLAUDE_MD" "CLAUDE.md"
else
    warning "No CLAUDE.md found"
fi
# CLAUDE.local.md — personal, gitignored overrides; dead-ref check too.
for cl in "$CLAUDE_DIR/CLAUDE.local.md" "$CLAUDE_DIR/../CLAUDE.local.md"; do
    [ -f "$cl" ] || continue
    check_dead_refs_in_file "$cl" "$(basename "$cl")"
done
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

# --- Check 5: Settings (validity, duplicates, dead guide refs, MCP, timeouts) ---
bold "--- Settings ---"
settings_checked=0
for settings_file in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
    [ -f "$settings_file" ] || continue
    settings_checked=$((settings_checked + 1))
    sdisp=$(basename "$settings_file")
    if check_json_valid "$settings_file" "$sdisp"; then
        check_json_duplicate_keys    "$settings_file" "$sdisp"
        check_json_duplicate_entries "$settings_file" "$sdisp"
        check_settings_guide_refs    "$settings_file" "$sdisp"
        check_mcp_preapproved        "$settings_file" "$sdisp"
        check_hook_timeouts          "$settings_file" "$sdisp"
    fi
done
if [ "$settings_checked" -eq 0 ]; then
    ok "No settings.json found (skipped)"
fi
echo ""

# --- Check 6: Hooks (registration) ---
bold "--- Hooks ---"
check_unregistered_hooks
echo ""

# --- Check 7: Auto-memory index size ---
bold "--- Memory ---"
check_memory_overflow
echo ""

# --- Check 8: Path-scoped rules ---
bold "--- Rules ---"
check_rules
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
