#!/usr/bin/env bash
# validate-skills.sh — Deterministic compliance checks for .claude/ ecosystem
# Based on Anthropic's official best practices (verified 2026-05-28; thresholds
# re-checked against the live docs with no drift — name 64 / desc 1024 / skill
# 500 lines / memory 200 lines+25600 bytes / listing 1% & 8000 floor & 1536 entry /
# hook timeouts 600/30/60 + UserPromptSubmit 30):
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
AGENTS_DIR="$CLAUDE_DIR/agents"
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
DESC_MIN=40
NAME_MAX=64
SKILL_MAX_LINES=500
SKILL_REF_DIR_THRESHOLD=300
REF_TOC_THRESHOLD=100
CLAUDE_MD_MAX_LINES=200
IMPORT_MAX_DEPTH=4
RESERVED_NAMES=("anthropic" "claude")
KNOWN_FRONTMATTER_FIELDS=("name" "description" "when_to_use" "allowed-tools" "disallowed-tools" "argument-hint" "arguments" "model" "color" "user-invocable" "disable-model-invocation" "effort" "context" "agent" "hooks" "paths" "shell" "hide-from-slash-command-tool")
MODEL_WHITELIST_RE='^(opus|sonnet|haiku|fable|inherit|claude-(opus|sonnet|haiku|fable)-[0-9])'
# enforceAvailableModels (settings.json, then settings.local.json overriding): when
# true with a non-empty availableModels list, a skill/agent `model:` outside that set
# is flagged MODEL-NOT-AVAILABLE. Matched at family level (opus|sonnet|haiku|fable) so
# an alias like `model: opus` is satisfied by any `claude-opus-*` entry — keeps FP low.
ENFORCE_MODELS=0
AVAILABLE_MODELS=""
if command -v jq >/dev/null 2>&1; then
    for _sf in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
        [ -f "$_sf" ] || continue
        _ef=$(jq -r 'if .enforceAvailableModels == true then "1" elif .enforceAvailableModels == false then "0" else "" end' "$_sf" 2>/dev/null || echo "")
        [ -n "$_ef" ] && ENFORCE_MODELS="$_ef"
        _am=$(jq -r '(.availableModels // []) | if type=="array" then .[] else empty end' "$_sf" 2>/dev/null || true)
        [ -n "$_am" ] && AVAILABLE_MODELS="$_am"
    done
fi
# Support/utility directories under skills/ that are not themselves skills.
SKILLS_DIR_EXCLUDES=("bootstrap" "commands")
# Subagent frontmatter enums — the subagent schema (.claude/agents/<name>.md) differs
# from the skill schema: tools/disallowedTools (not allowed-tools), permissionMode,
# color, maxTurns, etc. See https://code.claude.com/docs/en/sub-agents
AGENT_COLOR_RE='^(red|blue|green|yellow|purple|orange|pink|cyan)$'
AGENT_PERMMODE_RE='^(default|acceptEdits|auto|dontAsk|bypassPermissions|plan)$'
# Fields a PLUGIN-provided subagent declares in vain — Claude Code silently ignores them.
AGENT_PLUGIN_FORBIDDEN=("hooks" "mcpServers" "permissionMode")
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
# Claude Code runtime/data paths a reference doc may legitimately MENTION in prose
# (e.g. "scans ~/.claude/projects/*.jsonl", "reads .claude/plugins/installed_plugins.json").
# These are not chained skill references, so they are exempt from CHAINED-REF; genuine
# cross-component links (.claude/skills/<other>/…, .claude/commands/<other>) still fire.
# shellcheck disable=SC2088  # the leading ~ is a literal regex char (matches "~/.claude/"), not a path to expand
CLAUDE_RUNTIME_PATHS_RE='~/\.claude/|\.claude/(projects|plugins|\.?cache|telemetry|usage-data|logs|statsig|todos|shell-snapshots|backups|ide)|\.claude/\.(credentials|claude)|\.claude\.json'

red()    { printf '\033[0;31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$1"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$1"; }
bold()   { printf '\033[1m%s\033[0m\n' "$1"; }

error()   { red   "[ERROR] $1"; ERRORS=$((ERRORS + 1)); EXIT_CODE=1; }
warning() { yellow "[WARN]  $1"; WARNINGS=$((WARNINGS + 1)); }

# model_in_available <model> — is `model` permitted under AVAILABLE_MODELS? Exact
# match, else family-level (the opus|sonnet|haiku|fable token in `model` appears in
# some allowed entry). `inherit` is never constrained.
model_in_available() {
    local model="$1" fam line
    [ "$model" = "inherit" ] && return 0
    while IFS= read -r line; do
        [ "$line" = "$model" ] && return 0
    done <<< "$AVAILABLE_MODELS"
    fam=$(printf '%s' "$model" | grep -oE 'opus|sonnet|haiku|fable' | head -1 || true)
    [ -n "$fam" ] && printf '%s\n' "$AVAILABLE_MODELS" | grep -qF "$fam" && return 0
    return 1
}
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

    # Check: description present, then length (40 min, 1024 hard, 1536 combined)
    desc=$(extract_field "$skill_file" "description")
    when_to_use=$(extract_field "$skill_file" "when_to_use")
    if [ -n "$desc" ]; then
        local desc_len=${#desc}
        # The min-length floor exists so a model-invoked SKILL has enough text to
        # trigger reliably. Slash-command files are user-invoked (typed as /name),
        # so a terse description is valid — docs require only a non-empty string.
        if [ "$is_skill_md" = 1 ] && [ "$desc_len" -lt "$DESC_MIN" ]; then
            error "[BAD-FRONTMATTER-SCHEMA] $skill_name: description is $desc_len chars (min: $DESC_MIN — too short to trigger reliably)"
        fi
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

    # Check: model field whitelist (when present).
    local model_field
    model_field=$(extract_field "$skill_file" "model")
    if [ -n "$model_field" ] && ! echo "$model_field" | grep -qE "$MODEL_WHITELIST_RE"; then
        error "[BAD-FRONTMATTER-SCHEMA] $skill_name: model '$model_field' not in {opus|sonnet|haiku|fable|inherit|claude-(opus|sonnet|haiku|fable)-N}"
    elif [ -n "$model_field" ] && [ "$ENFORCE_MODELS" = 1 ] && [ -n "$AVAILABLE_MODELS" ] && ! model_in_available "$model_field"; then
        warning "[MODEL-NOT-AVAILABLE] $skill_name: model '$model_field' not in settings availableModels (enforceAvailableModels is on)"
    fi

    # Check: allowed-tools syntax. Tokens look like `Read`, `WebFetch`, or
    # `Bash(...)` / `Bash(jq:*)` / `Bash(bash path:*)`. The documented forms are a
    # space- or comma-separated string OR a YAML list (block `- Read` or flow
    # `[Read, "Bash(x)"]`), so after stripping valid tokens the residue may
    # legitimately contain separators (spaces, commas), YAML list dashes, flow-list
    # brackets and element quotes; anything ELSE means the field is malformed.
    # NB: keep the hyphen LAST in the tr set so it stays literal, not a range.
    local allowed_tools_field at_remainder
    allowed_tools_field=$(extract_field "$skill_file" "allowed-tools")
    if [ -n "$allowed_tools_field" ]; then
        at_remainder=$(printf '%s' "$allowed_tools_field" | sed -E 's/[A-Z][A-Za-z_]+(\([^()]*\))?//g' | tr -d ' \t\n,[]"'\''-')
        if [ -n "$at_remainder" ]; then
            error "[BAD-FRONTMATTER-SCHEMA] $skill_name: allowed-tools has unparseable residue '$at_remainder' — token shape is Name or Name(args)"
        fi
    fi

    # Check: unknown frontmatter keys. Scan top-level keys between the first
    # two `---` markers and compare to KNOWN_FRONTMATTER_FIELDS. Indented keys
    # (nested mappings) are not flagged.
    local frontmatter_keys key found k
    frontmatter_keys=$(awk '
        /^---[[:space:]]*$/ { if (++c == 2) exit; next }
        c == 1 && /^[a-zA-Z_][a-zA-Z0-9_-]*:/ { sub(/:.*/, ""); print }
    ' "$skill_file" 2>/dev/null | sort -u || true)
    if [ -n "$frontmatter_keys" ]; then
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            found=0
            for k in "${KNOWN_FRONTMATTER_FIELDS[@]}"; do
                [ "$key" = "$k" ] && { found=1; break; }
            done
            [ "$found" = 0 ] && warning "[UNKNOWN-FRONTMATTER-FIELD] $skill_name: key '$key' is not in the known frontmatter set"
        done <<< "$frontmatter_keys"
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
            s = $0; gsub(/`[^`]*`/, " ", s)
            gsub(/[^A-Za-z0-9._\/-]/, " ", s); n = split(s, a, " ")
            for (i = 1; i <= n; i++)
                if (a[i] ~ /^references\/[A-Za-z0-9._\/-]+\.md$/) print a[i]
        }' "$skill_file" 2>/dev/null | sort -u || true)
    fi

    check_embedded_secrets      "$skill_file" "$skill_name"
    check_unflagged_destructive "$skill_file" "$skill_name"
}

validate_agent_md() {
    # Validates a subagent definition (.claude/agents/<name>.md). Distinct from
    # validate_skill_md: the subagent schema uses tools/disallowedTools/permissionMode/
    # color/maxTurns, so reusing the skill validator would mis-flag valid agent fields.
    # Args: <file> <display-name> <is-plugin-tree:0|1>
    local agent_file="$1" display="$2" is_plugin="$3"
    local desc model_field color_field permmode_field name_field tf tools_field at_remainder ff

    # description is required — without it the agent cannot be delegation-routed.
    desc=$(extract_field "$agent_file" "description")
    [ -z "$desc" ] && error "[AGENT-BAD-SCHEMA] $display: no 'description' in frontmatter (required for delegation routing)"

    # model whitelist (shared with skills).
    model_field=$(extract_field "$agent_file" "model")
    if [ -n "$model_field" ] && ! echo "$model_field" | grep -qE "$MODEL_WHITELIST_RE"; then
        error "[AGENT-BAD-SCHEMA] $display: model '$model_field' not in {opus|sonnet|haiku|fable|inherit|claude-(opus|sonnet|haiku|fable)-N}"
    elif [ -n "$model_field" ] && [ "$ENFORCE_MODELS" = 1 ] && [ -n "$AVAILABLE_MODELS" ] && ! model_in_available "$model_field"; then
        warning "[MODEL-NOT-AVAILABLE] $display: model '$model_field' not in settings availableModels (enforceAvailableModels is on)"
    fi

    # color enum.
    color_field=$(extract_field "$agent_file" "color")
    if [ -n "$color_field" ] && ! echo "$color_field" | grep -qE "$AGENT_COLOR_RE"; then
        error "[AGENT-BAD-SCHEMA] $display: color '$color_field' not in {red|blue|green|yellow|purple|orange|pink|cyan}"
    fi

    # permissionMode enum, then the bypassPermissions security flag.
    permmode_field=$(extract_field "$agent_file" "permissionMode")
    if [ -n "$permmode_field" ]; then
        if ! echo "$permmode_field" | grep -qE "$AGENT_PERMMODE_RE"; then
            error "[AGENT-BAD-SCHEMA] $display: permissionMode '$permmode_field' not in {default|acceptEdits|auto|dontAsk|bypassPermissions|plan}"
        elif [ "$permmode_field" = "bypassPermissions" ]; then
            error "[AGENT-BYPASS-PERMS] $display: permissionMode 'bypassPermissions' disables every permission prompt for this agent"
        fi
    fi

    # tools / disallowedTools token shape — Name, Name(args), or mcp__server__tool.
    for tf in tools disallowedTools; do
        tools_field=$(extract_field "$agent_file" "$tf")
        [ -z "$tools_field" ] && continue
        # Subagent docs document `tools` only as a comma-separated string (and the
        # CLI as a JSON array) — never an inline YAML flow-list in file frontmatter.
        # Flag the flow-list with a clear message instead of "unparseable residue '[]'".
        case "$tools_field" in
            \[*)
                error "[AGENT-BAD-SCHEMA] $display: $tf uses an inline YAML flow-list ('[...]'); the documented form is a comma-separated string (e.g. 'Read, Grep') or a YAML block list"
                continue
                ;;
        esac
        at_remainder=$(printf '%s' "$tools_field" | sed -E 's/(mcp__[A-Za-z0-9_]+|[A-Z][A-Za-z_]+(\([^()]*\))?)//g' | tr -d ' \t\n,-')
        if [ -n "$at_remainder" ]; then
            error "[AGENT-BAD-SCHEMA] $display: $tf has unparseable residue '$at_remainder' — token shape is Name, Name(args), or mcp__server__tool"
        fi
    done

    # name charset — lowercase letters, numbers, hyphens. The filename need NOT match
    # the name: per the sub-agents spec the `name` field is the identifier, the filename
    # is free (e.g. agents/01-injection.md with name 'security-finder-injection').
    name_field=$(extract_field "$agent_file" "name")
    if [ -n "$name_field" ] && ! echo "$name_field" | grep -Eq '^[a-z0-9-]+$'; then
        error "[AGENT-BAD-SCHEMA] $display: name '$name_field' must be lowercase letters, numbers, and hyphens only"
    fi

    # Plugin-provided agents silently ignore hooks/mcpServers/permissionMode.
    if [ "$is_plugin" = 1 ]; then
        for ff in "${AGENT_PLUGIN_FORBIDDEN[@]}"; do
            [ -n "$(extract_field "$agent_file" "$ff")" ] \
                && warning "[AGENT-PLUGIN-FORBIDDEN-FIELD] $display: plugin agents ignore '$ff' frontmatter (declare it at plugin level instead)"
        done
    fi

    check_embedded_secrets      "$agent_file" "$display"
    check_unflagged_destructive "$agent_file" "$display"
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
    # shellcheck disable=SC2088  # the "~/.claude/" pattern is a literal tilde (as written in a settings file), not an expansion
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

# Ground a single `npm run <script>` against the nearest package.json. Walks from
# $1 (a directory) up to the filesystem root. Exit status:
#   0 = a package.json on the path defines the script   (live — do not flag)
#   1 = package.json(s) exist on the path, none define it (dead — flag)
#   2 = no package.json anywhere on the path, or no jq    (cannot ground — skip)
_npm_script_status() {
    local script="$1" dir saw_pkg=0
    command -v jq >/dev/null 2>&1 || return 2
    dir=$(cd "$2" 2>/dev/null && pwd) || return 2
    while :; do
        if [ -f "$dir/package.json" ]; then
            saw_pkg=1
            jq -e --arg s "$script" '(.scripts // {})[$s] // empty' "$dir/package.json" >/dev/null 2>&1 && return 0
        fi
        [ "$dir" = "/" ] && break
        dir=$(dirname "$dir")
    done
    [ "$saw_pkg" = 1 ] && return 1 || return 2
}

# Flag `npm run <script>` mentions in a text file whose <script> is defined in no
# package.json from the file's directory up to the filesystem root (CLAUDEMD-DEAD-SCRIPT).
# `npm run <name>` always requires a `.scripts.<name>` entry, so the grep is
# self-constraining — lifecycle verbs (`npm install`/`npm ci`/`npm test`) never match.
# Placeholder tokens like `<app>:start` carry a `<` and are skipped by the charset.
# When no package.json exists on the path, grounding is impossible and nothing is flagged.
check_npm_scripts_in_file() {
    local src="$1" display="$2" script base_dir
    [ -f "$src" ] || return 0
    base_dir=$(dirname "$src")
    local status
    while IFS= read -r script; do
        [ -z "$script" ] && continue
        _npm_script_status "$script" "$base_dir" && status=0 || status=$?
        [ "$status" = 1 ] && error "[CLAUDEMD-DEAD-SCRIPT] $display: \`npm run $script\` is not defined in package.json"
    done < <(grep -oE 'npm run [A-Za-z0-9:_-]+' "$src" 2>/dev/null | awk '{print $3}' | sort -u || true)
}

# Print the @import tokens of a markdown file. An import is `@<path>` at line start
# or after whitespace, where the path either ends in an extension or starts with
# ./ ../ ~/ or / — this avoids matching @mentions, emails, and npm scopes. Fenced
# code blocks are skipped.
_extract_imports() {
    awk '
        /^[[:space:]]*```/ { infence = !infence; next }
        infence { next }
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                if (substr($0, i, 1) == "@" && (i == 1 || substr($0, i-1, 1) ~ /[[:space:]]/)) {
                    rest = substr($0, i+1)
                    if (match(rest, /^[A-Za-z0-9._~\/-]+/)) {
                        tok = substr(rest, 1, RLENGTH)
                        if (tok ~ /\.[A-Za-z0-9]{1,5}$/ || tok ~ /^(\.\/|\.\.\/|~\/|\/)/) print tok
                    }
                }
            }
        }
    ' "$1" 2>/dev/null
}

# Recursively follow @imports from a CLAUDE.md / CLAUDE.local.md. Flags imports
# that do not resolve (CLAUDEMD-DEAD-IMPORT) and chains deeper than the documented
# 4-hop limit (IMPORT-TOO-DEEP). Cycle-safe via a visited set.
_imports_visited=""
_too_deep_flagged=0
walk_imports() {
    local file="$1" display="$2" depth="$3" base_dir tok resolved
    [ -f "$file" ] || return 0
    base_dir=$(dirname "$file")
    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        # shellcheck disable=SC2088  # the "~/" pattern is a literal tilde from the @import token text, matched not expanded
        case "$tok" in
            '~/'*) resolved="$HOME/${tok#\~/}" ;;
            /*)    resolved="$tok" ;;
            ./*)   resolved="$base_dir/${tok#./}" ;;
            *)     resolved="$base_dir/$tok" ;;
        esac
        if [ ! -e "$resolved" ]; then
            error "[CLAUDEMD-DEAD-IMPORT] $display: import @$tok does not resolve (looked at $resolved)"
            continue
        fi
        if [ "$depth" -ge "$IMPORT_MAX_DEPTH" ] && [ "$_too_deep_flagged" = 0 ]; then
            warning "[IMPORT-TOO-DEEP] $display: @import chain exceeds $IMPORT_MAX_DEPTH hops (at @$tok)"
            _too_deep_flagged=1
        fi
        case "$_imports_visited" in *"|$resolved|"*) continue ;; esac
        _imports_visited="$_imports_visited|$resolved|"
        walk_imports "$resolved" "@$tok" $((depth + 1))
    done < <(_extract_imports "$file")
}

# A CLAUDE.local.md holds personal overrides and should be gitignored. Deterministic
# (no git binary): walk up to the repo root looking for a .gitignore that covers it.
# Fires only inside a git working tree — a non-repo ~/.claude has nothing to ignore.
check_local_md_tracked() {
    local cl dir found in_repo
    for cl in "$CLAUDE_DIR/CLAUDE.local.md" "$CLAUDE_DIR/../CLAUDE.local.md"; do
        [ -f "$cl" ] || continue
        dir=$(cd "$(dirname "$cl")" 2>/dev/null && pwd) || continue
        found=0; in_repo=0
        while [ -n "$dir" ] && [ "$dir" != "/" ]; do
            if [ -f "$dir/.gitignore" ] && grep -qE '(^|/)(CLAUDE\.local\.md|\*\.local\.md|CLAUDE\.\*)' "$dir/.gitignore" 2>/dev/null; then
                found=1; break
            fi
            if [ -d "$dir/.git" ]; then in_repo=1; break; fi
            dir=$(dirname "$dir")
        done
        [ "$in_repo" = 1 ] && [ "$found" = 0 ] \
            && warning "[LOCAL-MD-TRACKED] $(basename "$cl"): inside a git repo but not covered by a .gitignore — personal overrides should be gitignored"
    done
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

# Static safety scan of hook scripts in hooks/. High-precision heuristics only:
#   - HOOK-NO-SHEBANG: first line is not a #! shebang (content-based; the
#     executable bit is deliberately NOT checked — git/CI does not preserve it).
#   - HOOK-EXIT-NONBLOCKING: emits a block/deny decision yet exits 1 with no
#     exit 2 anywhere — exit 1 is non-blocking, only exit 2 blocks the action.
#   - HOOK-UNSAFE-SHELL: eval of a dynamic value (`eval ...$...`) — never eval
#     tool-supplied stdin.
check_hook_scripts() {
    local hooks_dir="$CLAUDE_DIR/hooks" h base first code
    [ -d "$hooks_dir" ] || return 0
    for h in "$hooks_dir"/*.sh; do
        [ -f "$h" ] || continue
        base=$(basename "$h")
        first=$(head -1 "$h" 2>/dev/null || true)
        case "$first" in
            '#!'*) : ;;
            *) warning "[HOOK-NO-SHEBANG] $base: first line is not a #! shebang (e.g. #!/usr/bin/env bash)" ;;
        esac
        # Strip full-line comments (and the shebang) so documented/example code — a
        # commented-out eval, a sample block decision — does not trip the heuristics.
        code=$(grep -vE '^[[:space:]]*#' "$h" 2>/dev/null || true)
        if printf '%s\n' "$code" | grep -qE '"?decision"?[[:space:]]*:[[:space:]]*"?block|"?permissionDecision"?[[:space:]]*:[[:space:]]*"?deny' \
           && printf '%s\n' "$code" | grep -qE '(^|[^0-9])exit[[:space:]]+1([^0-9]|$)' \
           && ! printf '%s\n' "$code" | grep -qE '(^|[^0-9])exit[[:space:]]+2([^0-9]|$)'; then
            warning "[HOOK-EXIT-NONBLOCKING] $base: emits a block/deny decision but exits 1 — only exit 2 blocks the action (exit 1 is non-blocking)"
        fi
        if printf '%s\n' "$code" | grep -qE '(^|[^A-Za-z0-9_])eval[[:space:]]+[^#]*\$'; then
            warning "[HOOK-UNSAFE-SHELL] $base: eval of a dynamic value (\$...) — never eval tool-supplied input"
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

# Flag `.claude/<file>` path citations in auto-memory file BODIES that no longer
# resolve in the scanned tree → MEMORY-STALE-CONTENT (a memory pointing at a script,
# guide, or config that has since been removed/renamed). This is the deterministic
# slice of memory content-grounding; behaviour-contradiction claims stay judgment
# (Phase 20). Runtime/state paths a memory legitimately mentions are skipped.
check_memory_stale_refs() {
    local memf disp p
    while IFS= read -r memf; do
        [ -f "$memf" ] || continue
        disp="projects/${memf#"$CLAUDE_DIR"/projects/}"
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            printf '%s' "$p" | grep -qE "$CLAUDE_RUNTIME_PATHS_RE" && continue
            [ -f "$(_resolve_dotclaude "$p")" ] || error "[MEMORY-STALE-CONTENT] $disp: cites $p — missing on disk"
        done < <(grep -oE '(~/)?\.claude/[A-Za-z0-9._/-]+\.(md|sh|json|ts|js)' "$memf" 2>/dev/null | sort -u || true)
    done < <(find "$CLAUDE_DIR/projects" -path '*/memory/*.md' 2>/dev/null | sort)
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

# Flag http hooks that carry an auth-bearing header but scope no env vars. Without
# allowedEnvVars (per-hook) or httpHookAllowedEnvVars (top-level), Claude Code sends
# the entire environment to the hook URL — leaking unrelated secrets.
check_http_hook_env() {
    local json_file="$1" display="$2" leak
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    leak=$(jq -r '
        (.httpHookAllowedEnvVars // null) as $top
        | (.hooks // {}) | to_entries[] | .value[]? | .hooks[]?
        | select(.type == "http")
        | select(.allowedEnvVars == null and $top == null)
        | select(.headers != null)
        | select([ .headers | to_entries[] | ((.key) + " " + (.value | tostring)) | ascii_downcase ]
                 | any(test("authorization|api.?key|token|secret|bearer|\\$\\{")))
        | (.url // "http hook")
    ' "$json_file" 2>/dev/null | head -1 || true)
    if [ -n "$leak" ]; then
        warning "[HOOK-ENV-LEAK] $display: http hook ($leak) sends an auth header with no allowedEnvVars/httpHookAllowedEnvVars — the whole environment is forwarded"
    fi
}

# Flag settings keys that broadly loosen the permission sandbox. bypassPermissions
# auto-approves every tool call; enableAllProjectMcpServers trusts any project
# .mcp.json without review. Both are valid keys — the finding is the risk, not a
# schema error.
check_settings_security() {
    local json_file="$1" display="$2" mode
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    mode=$(jq -r '(.permissions.defaultMode // .defaultMode) // empty' "$json_file" 2>/dev/null)
    if [ "$mode" = "bypassPermissions" ]; then
        error "[SETTINGS-BYPASS-MODE] $display: defaultMode is \"bypassPermissions\" — every tool call is auto-approved with no prompt"
    fi
    if [ "$(jq -r '.enableAllProjectMcpServers // false' "$json_file" 2>/dev/null)" = "true" ]; then
        warning "[SETTINGS-MCP-AUTOAPPROVE] $display: enableAllProjectMcpServers is true — every project MCP server is trusted without review"
    fi
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

# Scan a markdown file for embedded credentials (real-looking API keys / tokens).
# Skips placeholder lines (example, $VAR, <your-key>, xxxx, 0000, redacted).
# Patterns target well-known credential prefixes that have low false-positive rates.
check_embedded_secrets() {
    local file="$1" display="$2" hit ln rest snippet
    [ -f "$file" ] || return 0
    while IFS=: read -r ln rest; do
        [ -z "$ln" ] && continue
        if printf '%s' "$rest" | grep -qiE '(example|placeholder|your[-_]?(key|token|secret|api)|<your|xxxx|0000|redacted|replace[-_]?me|\$\{?[A-Z][A-Z0-9_]*\}?)'; then
            continue
        fi
        hit=$(printf '%s' "$rest" | grep -oE '\b(sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,})' | head -1)
        if [ -n "$hit" ]; then
            snippet=$(printf '%s' "$hit" | cut -c1-10)
            error "[EMBEDDED-SECRET] $display:$ln — credential pattern ${snippet}… in markdown body; replace with \$ENV_VAR placeholder"
        fi
    done < <(grep -nE '\b(sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,})' "$file" 2>/dev/null || true)
}

# Scan a markdown file for destructive shell commands lacking a nearby warning
# marker (⚠, WARNING, DANGER, --dry-run, confirm, etc.). Looks 5 lines before
# and 2 after each hit. Snippet is truncated to 60 chars to keep findings tight.
check_unflagged_destructive() {
    local file="$1" display="$2" ln snippet
    [ -f "$file" ] || return 0
    while IFS=$'\t' read -r ln snippet; do
        [ -z "$ln" ] && continue
        warning "[UNFLAGGED-DESTRUCTIVE] $display:$ln — $snippet — add WARNING note, ⚠ marker, or --dry-run guard"
    done < <(awk '
        function has_warn(s,    t) {
            if (s ~ /⚠/) return 1
            t = tolower(s)
            return t ~ /warning|danger|destructive|confirm|--dry-run|do not run|never run|caution|do not modify|block|prevent|deny|disallow|forbid|pattern|regex|example|e\.g\./
        }
        function is_dest(s,    t) {
            t = tolower(s)
            return t ~ /rm[[:space:]]+-rf/ \
                || t ~ /git[[:space:]]+push[[:space:]]+(--force|-f([[:space:]]|$))/ \
                || t ~ /git[[:space:]]+reset[[:space:]]+--hard/ \
                || t ~ /(^|[^a-z])drop[[:space:]]+(table|database|schema)/ \
                || t ~ /truncate[[:space:]]+table/ \
                || t ~ /mkfs\./ \
                || t ~ /chmod[[:space:]]+-r[[:space:]]+777/ \
                || (t ~ /dd[[:space:]]+if=/ && t ~ /of=\/dev\//)
        }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (lines[i] ~ /^[[:space:]]*(disallowedTools|disallowed-tools)[[:space:]]*:/) continue
                if (lines[i] ~ /\\s/) continue
                if (is_dest(lines[i])) {
                    warned = 0
                    s = (i - 5 < 1 ? 1 : i - 5)
                    e = (i + 2 > NR ? NR : i + 2)
                    for (j = s; j <= e; j++) {
                        if (has_warn(lines[j])) { warned = 1; break }
                    }
                    if (!warned) {
                        snip = lines[i]
                        sub(/^[[:space:]]+/, "", snip)
                        if (length(snip) > 60) snip = substr(snip, 1, 57) "..."
                        printf "%d\t%s\n", i, snip
                    }
                }
            }
        }
    ' "$file" 2>/dev/null || true)
}

# Detect basename overlap between skills/ and commands/. Same name in both
# namespaces shadows in the slash-command UI; skill wins per docs but the
# duplication is a maintenance trap and worth flagging.
check_name_collisions() {
    [ -d "$SKILLS_DIR" ] || return 0
    [ -d "$COMMANDS_DIR" ] || return 0
    local skill_names cmd_names common name skip ex
    skill_names=$(
        for d in "$SKILLS_DIR"/*/; do
            [ -d "$d" ] || continue
            name=$(basename "$d"); skip=0
            for ex in "${SKILLS_DIR_EXCLUDES[@]}"; do [ "$name" = "$ex" ] && skip=1 && break; done
            [ "$skip" = 1 ] && continue
            printf '%s\n' "$name"
        done | sort -u
    )
    cmd_names=$(
        for f in "$COMMANDS_DIR"/*.md; do
            [ -f "$f" ] || continue
            printf '%s\n' "$(basename "$f" .md)"
        done | sort -u
    )
    [ -z "$skill_names" ] && return 0
    [ -z "$cmd_names" ] && return 0
    common=$(comm -12 <(printf '%s' "$skill_names") <(printf '%s' "$cmd_names"))
    if [ -n "$common" ]; then
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            error "[NAME-COLLISION] $name: defined in both skills/$name/SKILL.md and commands/$name.md (skill wins; duplication is a maintenance trap)"
        done <<< "$common"
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
    check_npm_scripts_in_file "$CLAUDE_MD" "CLAUDE.md"
    walk_imports "$CLAUDE_MD" "CLAUDE.md" 0
else
    warning "No CLAUDE.md found"
fi
# CLAUDE.local.md — personal, gitignored overrides; dead-ref + import checks too.
for cl in "$CLAUDE_DIR/CLAUDE.local.md" "$CLAUDE_DIR/../CLAUDE.local.md"; do
    [ -f "$cl" ] || continue
    check_dead_refs_in_file "$cl" "$(basename "$cl")"
    check_npm_scripts_in_file "$cl" "$(basename "$cl")"
    walk_imports "$cl" "$(basename "$cl")" 0
done
# Guides CLAUDE.md routes to — ground their `npm run` mentions the same way.
if [ -d "$CLAUDE_DIR/documentation/guides" ]; then
    while IFS= read -r g; do
        check_npm_scripts_in_file "$g" "documentation/guides/$(basename "$g")"
    done < <(find "$CLAUDE_DIR/documentation/guides" -name '*.md' 2>/dev/null | sort)
fi
check_local_md_tracked
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
        # Conventional repo docs that live in commands/ are not slash commands —
        # don't validate their filename as a command name (e.g. README → BAD-NAME).
        case "$(basename "$cmd_file" | tr '[:upper:]' '[:lower:]')" in
            readme.md|changelog.md|license.md|contributing.md) continue ;;
        esac
        validate_skill_md "$cmd_file" "commands/$(basename "$cmd_file")"
    done
else
    ok "No $COMMANDS_DIR directory (skipped)"
fi
echo ""

# --- Check 3b: Agents (subagent .md files) ---
bold "--- Agents ---"
if [ -d "$AGENTS_DIR" ]; then
    is_plugin_tree=0
    [ -f "$CLAUDE_DIR/.claude-plugin/plugin.json" ] && is_plugin_tree=1
    agent_names=""
    for agent_file in "$AGENTS_DIR"/*.md; do
        [ -f "$agent_file" ] || continue
        a_display="agents/$(basename "$agent_file")"
        validate_agent_md "$agent_file" "$a_display" "$is_plugin_tree"
        a_name=$(extract_field "$agent_file" "name")
        [ -z "$a_name" ] && a_name=$(basename "$agent_file" .md)
        agent_names="${agent_names}${a_name}"$'\n'
    done
    dup_names=$(printf '%s' "$agent_names" | grep -v '^$' | sort | uniq -d || true)
    if [ -n "$dup_names" ]; then
        while IFS= read -r dn; do
            [ -z "$dn" ] && continue
            warning "[AGENT-DUP-NAME] agents/: name '$dn' is shared by more than one agent file (one is silently discarded)"
        done <<< "$dup_names"
    fi
else
    ok "No $AGENTS_DIR directory (skipped)"
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
              | grep -Ev "$CLAUDE_RUNTIME_PATHS_RE" \
              | grep -Ev "\.claude/(${skill_name}(/|\.[a-zA-Z0-9]+)|reports[/'\"\` ]?)" \
              | grep -E '\.claude/[A-Za-z0-9._-]+/' | head -3 || true)
    if [ -n "$chained" ]; then
        error "[CHAINED-REF] $ref_name links to external .claude/ path (allowed: .claude/$skill_name/ or .claude/$skill_name.*)"
        echo "    $chained" | head -2
    fi

    check_embedded_secrets      "$ref_file" "$ref_name"
    check_unflagged_destructive "$ref_file" "$ref_name"
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
                  | grep -Ev "$CLAUDE_RUNTIME_PATHS_RE" \
                  | grep -Ev "\.claude/${sub}(/|\.[a-zA-Z0-9]+)" \
                  | grep -E '\.claude/[A-Za-z0-9._-]+/' | head -3 || true)
        if [ -n "$chained" ]; then
            error "[CHAINED-REF] $ref_name links to external .claude/ path (allowed: .claude/$sub/ or .claude/$sub.*)"
            echo "    $chained" | head -2
        fi

        check_embedded_secrets      "$ref_file" "$ref_name"
        check_unflagged_destructive "$ref_file" "$ref_name"
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
        check_http_hook_env          "$settings_file" "$sdisp"
        check_settings_security      "$settings_file" "$sdisp"
    fi
done
if [ "$settings_checked" -eq 0 ]; then
    ok "No settings.json found (skipped)"
fi
echo ""

# --- Check 6: Hooks (registration + script safety) ---
bold "--- Hooks ---"
check_unregistered_hooks
check_hook_scripts
echo ""

# --- Check 7: Auto-memory index size + stale body references ---
bold "--- Memory ---"
check_memory_overflow
check_memory_stale_refs
echo ""

# --- Check 8: Path-scoped rules ---
bold "--- Rules ---"
check_rules
echo ""

# --- Check 9: Name collisions (commands vs skills) ---
bold "--- Name Collisions ---"
check_name_collisions
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
