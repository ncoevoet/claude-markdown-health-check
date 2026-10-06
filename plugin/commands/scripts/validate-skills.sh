#!/usr/bin/env bash
# validate-skills.sh — Deterministic compliance checks for .claude/ ecosystem
# Based on Anthropic's official best practices (verified 2026-10-06; adds XML tags in
# descriptions, Windows paths, time-sensitive wording, vague names and reserved-word
# portability; thresholds
# re-checked against the live docs with no drift — name 64 / desc 1024 / skill
# 500 lines / memory 200 lines+25600 bytes / listing 1% & 8000 floor & 1536 entry /
# hook timeouts per event: command/http/mcp_tool 600, but 30 on UserPromptSubmit/
# PreModelSwitch/PostModelSwitch and 10 on MessageDisplay; prompt 30; agent 60;
# SessionEnd capped at 60):
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
# Optional flags: --listing-cost prints machine-readable budget stats and exits;
# --anchors prints machine-readable unique-anchor-token JSON and exits.
# Accepts either flag in any position; the first non-flag positional is CLAUDE_DIR.
LISTING_COST_ONLY=0
ANCHORS_ONLY=0
POS_ARGS=()
for a in "$@"; do
    case "$a" in
        --listing-cost) LISTING_COST_ONLY=1 ;;
        --anchors) ANCHORS_ONLY=1 ;;
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
RESERVED_SKILL_DIR="synced"
# Agent Skills best-practices checks. Skill-only (is_skill_md=1): command files
# legitimately carry <arg> placeholders and are not uploadable skills.
# Generic skill names / non-descriptive reference filenames (digits required so
# notes.md and misc.md stay out of scope).
VAGUE_SKILL_NAME_RE='^(helpers?|utils?|tools?|documents?|data|files?)$'
VAGUE_REF_NAME_RE='^(doc|file)[0-9]+\.md$'
# Case-insensitive SUBSTRING (grep -Ei): the docs say a name may not "contain" these.
RESERVED_WORD_RE='anthropic|claude'
# Tags: bare (<b>, </b>), self-closing with optional whitespace (<br />), with
# name="v" / name='v' / name=v attributes (<example name="a">), and generic types
# with a comma list (Map<K,V>, Map<K, V>; not followed by an identifier char so
# `x<y, z>w` stays out). `x<y and y>z` and `a < b > c` do not match.
DESC_XML_TAG_RE="</?[A-Za-z][A-Za-z0-9_:-]*([[:space:]]+[A-Za-z_:][A-Za-z0-9_:.-]*=(\"[^\"]*\"|'[^']*'|[^[:space:]\"'<>=/]+))*[[:space:]]*/?>"
DESC_GENERIC_RE='[A-Za-z_][A-Za-z0-9_]*<[A-Za-z_][A-Za-z0-9_.]*(,[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*)+>([^A-Za-z0-9_]|$)'
# A backslash path with a file extension (scripts\helper.py). Segment 2 must start
# alphanumeric so markdown escapes like snake\_case.py do not match.
WINDOWS_PATH_RE='[A-Za-z0-9_.-]+\\[A-Za-z0-9][A-Za-z0-9_.-]*\.[A-Za-z0-9]{1,5}\b'
# before/after/until/as of/since <Month> [day,] <YYYY>, or day-first. Used with grep -Ei.
# Exact full month names or the 3-letter abbreviations, optional dot ("Marching" is no month).
TIME_MONTH='(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(tember)?|oct(ober)?|nov(ember)?|dec(ember)?)\.?'
TIME_SENSITIVE_RE='\b(before|after|until|as +of|since) +('"$TIME_MONTH"' +([0-9]{1,2},? +)?[0-9]{4}|[0-9]{1,2} +'"$TIME_MONTH"' +[0-9]{4})\b'
KNOWN_FRONTMATTER_FIELDS=("name" "description" "when_to_use" "allowed-tools" "disallowed-tools" "argument-hint" "arguments" "model" "color" "user-invocable" "disable-model-invocation" "effort" "context" "agent" "hooks" "paths" "shell" "hide-from-slash-command-tool" "background" "metadata" "license" "compatibility")
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
# allowedHttpHookUrls (docs: "Supports * as a wildcard. When set, hooks with
# non-matching URLs are blocked. Undefined = no restrictions, empty array = block all
# HTTP hooks. Arrays merge across settings sources."). A blocked hook never runs, so a
# non-matching url is silent breakage, not a style choice.
HTTP_URL_ALLOWLIST_SET=0
HTTP_URL_ALLOWLIST=""
if command -v jq >/dev/null 2>&1; then
    for _sf in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
        [ -f "$_sf" ] || continue
        jq -e 'has("allowedHttpHookUrls")' "$_sf" >/dev/null 2>&1 || continue
        HTTP_URL_ALLOWLIST_SET=1
        _al=$(jq -r '(.allowedHttpHookUrls // []) | if type=="array" then .[] else empty end' "$_sf" 2>/dev/null || true)
        if [ -n "$_al" ]; then
            HTTP_URL_ALLOWLIST="${HTTP_URL_ALLOWLIST}${_al}"$'\n'
        fi
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
AGENT_PLUGIN_FORBIDDEN=("hooks" "mcpServers" "permissionMode" "initialPrompt")
# Context-engineering thresholds — see
# https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models
# ("we were overconstraining Claude Code", "delete these repeat examples").
# Only ALL-CAPS absolutes count: a lowercase "must" in prose is normal English,
# a shouted one is a hard rule. Calibrated on real trees — ordinary skills land at
# 0–8 hits per 100 body lines, an "ABSOLUTE RULE"-style CLAUDE.md at 18.
ABSOLUTE_DIRECTIVE_RE="\b(NEVER|ALWAYS|MUST NOT|MUST|DO NOT|DON'T|MANDATORY|STRICTLY FORBIDDEN|ABSOLUTE)\b"
OVERCONSTRAINT_MIN_BODY=40
OVERCONSTRAINT_MIN_HITS=8
OVERCONSTRAINT_PER_100=12
DUPLICATED_INSTRUCTION_MIN_CHARS=40
OBVIOUS_LISTING_MIN_LINES=6
OBVIOUS_LISTING_MIN_RESOLVED=3
MEMORY_DRIFT_MIN_BULLETS=3

# Auto-memory index budget (loaded slice) and hook-timeout defaults (seconds).
MEMORY_MAX_LINES=200
MEMORY_MAX_BYTES=25600
HOOK_TIMEOUT_COMMAND=600
HOOK_TIMEOUT_PROMPT=30
HOOK_TIMEOUT_AGENT=60
HOOK_TIMEOUT_FAST_EVENT=30
HOOK_TIMEOUT_MESSAGEDISPLAY=10
HOOK_TIMEOUT_SESSIONEND_CAP=60

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
    # YAML block scalar / wrapped value with spaces, and folds the indented
    # continuation lines of a plain scalar; prints "" when absent.
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
            cap = 1; val = v; next
        }
    ' "$file"
}

# --- Anchor-grade tokenizer (backs check_anchor_analysis / --anchors) ------
# The coder_eval study found the strongest lever for skill-activation recall
# is a trigger clause naming a token the skill uniquely owns — not a generic
# verb. These five classes are the only ones that count as "anchor-grade":
# a file extension, a dotted filename, a backticked literal, a hyphenated/
# compound lowercase identifier, or a capitalized mid-sentence proper noun.
# Everything else is too common to disambiguate.
ANCHOR_EXT_RE='\.[a-z0-9]{2,6}\b'
ANCHOR_DOTTED_RE='\b[a-z0-9_-]+\.[a-z0-9]{2,6}\b'
ANCHOR_BACKTICK_RE='`[^`]+`'
# Hyphenated/compound lowercase identifiers (`coder-eval`,
# `markdown-health-check`) read as domain-specific product/artifact
# names, not prose — but plenty of ordinary English is hyphenated too
# ("well-known", "built-in"). Matched lowercase-only (no `-i`) so a
# Capitalized-Hyphenated run (sentence-initial or not) is left to the
# proper-noun class instead of double-counted here.
ANCHOR_HYPHEN_RE='\b[a-z][a-z0-9]*(-[a-z0-9]+)+\b'
# Bare TLDs and URL hosts are not file extensions or filenames: a description
# mentioning `coder-eval.com` or `https://example.org/api` must not gain
# ".com"/"coder-eval.com"/".org"/"example.org" as anchor-grade tokens — any
# description containing a URL would otherwise pick up several "unique"
# tokens for free and could never trip NO-UNIQUE-ANCHOR. This is checked as a
# token-suffix filter (below, in anchor_tokens_from), never against real
# extension vocabulary, so genuine extensions (`.bpmn`, `.xml`, `.logx`) are
# unaffected. Heuristic/curated, same spirit as ANCHOR_VERB_BLOCKLIST_RE —
# not exhaustive.
ANCHOR_TLD_BLOCKLIST_RE='\.(com|org|net|io|dev|co|gov|edu|info|biz|app|ai|me|us|uk|ca|eu|gg|sh|xyz|tech|cloud|online|site|blog|ly|to|tv)$'
# Heuristic for "capitalized, not sentence-initial" without a real sentence
# tokenizer: a lowercase letter directly followed by whitespace then a
# Capitalized word. A period breaks that adjacency, so both string-start and
# post-". " capitals are excluded for free — but excluded is not the same as
# irrelevant: a sentence-initial product/brand name ("Confluence page
# operations…", "Jira ticket automation…") is a very common way to lead a
# description, and dropping it entirely is its own bug. Caught separately
# below by ANCHOR_PROPER_NOUN_INITIAL_RE, restricted to words NOT ending in
# "s": this codebase's own house style writes descriptions in third-person
# ("Handles X", "Reviews Y", "Coordinates Z" — see the THIRD-PERSON check),
# so a sentence-initial generic verb in that voice always ends in -s, while a
# leading proper noun usually does not. That one grammatical fact admits real
# leading proper nouns without reopening the whole generic-verb blocklist to
# every English verb.
ANCHOR_PROPER_NOUN_RE='[a-z][[:space:]]+[A-Z][A-Za-z]*'
ANCHOR_PROPER_NOUN_INITIAL_RE='(^[[:space:]]*|[.!?][[:space:]]+)[A-Z][A-Za-z]*'
# Generic verbs anchor nothing, and neither do ordinary hyphenated English
# adjectives/compounds that the hyphen class above would otherwise catch —
# both are subtracted before ownership is computed. Hyphenated additions:
# well-known, built-in, read-only, visual-design, real-time, long-running,
# self-contained, open-source, end-to-end, high-level, low-level, one-time,
# ad-hoc, follow-up, opt-in, no-op, up-to-date, hands-on, general-purpose,
# cross-platform, user-friendly, easy-to-use, non-functional.
ANCHOR_VERB_BLOCKLIST_RE='^(review|audit|check|fix|run|build|test|help|manage|handle|update|create|analyze|scan|verify|validate|generate|use|work|task|project|file|code|well-known|built-in|read-only|visual-design|real-time|long-running|self-contained|open-source|end-to-end|high-level|low-level|one-time|ad-hoc|follow-up|opt-in|no-op|up-to-date|hands-on|general-purpose|cross-platform|user-friendly|easy-to-use|non-functional)$'
# Ordinary English words admitted by the proper-noun classes above are not
# artifact names: on a real tree, "for" (sentence-initial), "rest"/"ci"/"sas"
# (mid-sentence, from "REST API"/"CI/CD"/"SAS test") and "auto"/"complete"
# (sentence-initial) all measured as *owned* — a downstream consumer that
# joins these tokens against raw prompt text would match a majority of
# unrelated prompts on a token like "ci". Two independent filters, since
# neither alone separates this from genuine short acronyms (JVM, SIP, ICP,
# SAS — real technical acronyms that are ALSO all-caps in source, so casing
# cannot be the discriminator, and "sip" is even a real dictionary word, so
# a system dictionary lookup would wrongly reject it too — hence a curated
# list, not a dictionary, and deliberately NOT exhaustive):
#   1. A length floor (below, in anchor_tokens_from): a 1-2 char token is
#      never a useful anchor regardless of what it is — this alone accounts
#      for "ci"/"mr". Harmless to every other class: ANCHOR_EXT_RE/
#      ANCHOR_DOTTED_RE require >=2 chars after the dot (min token length 3,
#      ".ts"/".md" included) and ANCHOR_HYPHEN_RE needs two segments (min
#      length 3, "a-b"), so real extensions/filenames/hyphenated identifiers
#      are never shortened by this floor.
#   2. This closed-class-plus-evidence word list, for tokens length 3+ that
#      the floor does not catch ("for", "rest", "auto", "complete", "pull").
#      Mostly closed-class English (determiners/pronouns/prepositions/
#      conjunctions — a bounded set, unlike open-class nouns/verbs) plus the
#      specific open-class words measured above. A real acronym never
#      collides with this list (SIP/JVM/ICP/SAS/CI/CVE are not English
#      function words), even when, like "sip", it also happens to have an
#      unrelated dictionary meaning nothing on this list captures.
ANCHOR_COMMON_WORD_RE='^(for|rest|auto|complete|pull|the|this|that|these|those|there|here|its|they|them|their|our|your|and|but|nor|yet|per|via|with|from|into|about|over|under|before|after|until|than|then|also|only|just|even|both|each|either|neither|any|some|none|many|much|own|same|more|most|new|old|top|way|out|off)$'
# The study's one-sentence intervention, expressed as a trigger-ish sentence
# matcher. The original four literal phrases (`always invoke for|use for|use
# when|triggers on`) measured near-100% false positive on real corpora — real
# descriptions overwhelmingly phrase it differently ("Use it for", "Use this
# skill when", "This skill should be used when", "Triggers on:", "Use to …").
# Broadened to the underlying verb families instead of a fixed phrase list,
# and matched per-sentence (see ANCHOR_SENTENCE_UNIT_RE below), not against
# just the text following the match: the tag's actual question is "does a
# token this skill uniquely owns appear anywhere in a use/trigger-ish
# context", not "does one specific phrase's tail happen to name it".
ANCHOR_TRIGGER_SENTENCE_RE='(\bus(e|es|ed|ing)\b.{0,40}\b(when|for|to|in|on|at|if)\b|\bshould be used\b|\balways invoke\b|\binvok(e|es|ed|ing)\b.{0,40}\b(when|for)\b|\btrigger(s|ed|ing)?\b)'
# A "sentence" is a maximal run that treats "period + 1-6 alnum + word
# boundary" as one atomic non-breaking unit, so a file extension like
# ".bpmn" is never mistaken for a sentence break — any other character that
# isn't a period passes through unchanged, so a run still ends at a genuine
# ". " or end-of-string. Used to split a description into sentences before
# testing each one against ANCHOR_TRIGGER_SENTENCE_RE.
ANCHOR_SENTENCE_UNIT_RE='([^.]|\.[A-Za-z0-9]{1,6}\b)+'

# anchor_tokens_from <text> -> one lowercased, blocklist-filtered anchor-grade
# token per line (deduped), extracted from <text>. Extraction runs on <text>
# as given (case preserved, needed for the proper-noun class); tokens are
# lowercased afterward so ownership comparison is case-insensitive.
anchor_tokens_from() {
    local text="$1"
    {
        printf '%s\n' "$text" | grep -ioE "$ANCHOR_EXT_RE" 2>/dev/null || true
        printf '%s\n' "$text" | grep -ioE "$ANCHOR_DOTTED_RE" 2>/dev/null || true
        printf '%s\n' "$text" | grep -oE "$ANCHOR_BACKTICK_RE" 2>/dev/null | tr -d '`' || true
        printf '%s\n' "$text" | grep -oE "$ANCHOR_HYPHEN_RE" 2>/dev/null || true
        printf '%s\n' "$text" | grep -oE "$ANCHOR_PROPER_NOUN_RE" 2>/dev/null | grep -oE '[A-Z][A-Za-z]*$' || true
        printf '%s\n' "$text" | grep -oE "$ANCHOR_PROPER_NOUN_INITIAL_RE" 2>/dev/null | grep -oE '[A-Z][A-Za-z]*$' | grep -vE '[sS]$' || true
    } | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/^[^a-z0-9.]+//; s/[^a-z0-9]+$//' \
      | awk 'length($0) >= 3' \
      | grep -vE "$ANCHOR_VERB_BLOCKLIST_RE" \
      | grep -vE "$ANCHOR_TLD_BLOCKLIST_RE" \
      | grep -vE "$ANCHOR_COMMON_WORD_RE" \
      | grep -v '^$' \
      | sort -u
    # A zero-token result is a legitimate outcome (that IS NO-UNIQUE-ANCHOR's
    # signal), but `grep -v` with nothing surviving exits 1 — under pipefail
    # that makes the pipeline's status nonzero and, under `set -e`, would abort
    # the whole script at `tokens=$(anchor_tokens_from ...)`. Force success.
    return 0
}

# A block-sequence item indented under a COMPLETED scalar mapping line is not
# valid YAML — the whole frontmatter fails to parse and the runtime falls back
# to the H1 title, silently destroying the skill's routing description. The
# common shape: a when_to_use-style list pasted directly under
# `description: "…"` with the key line itself missing. Detected structurally
# (no yaml parser dependency): an item line `^\s+- ` whose nearest preceding
# non-blank line is a top-level `key: value` scalar whose value is not a
# block-scalar marker (| or >). Prints the offending key, or nothing.
frontmatter_orphaned_list_key() {
    awk '
        NR == 1 { if ($0 ~ /^---[[:space:]]*$/) { in_fm = 1 }; next }
        !in_fm { exit }
        /^---[[:space:]]*$/ { exit }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]+- / {
            if (prev_key != "") { print prev_key; exit }
            next
        }
        {
            prev_key = ""
            if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]*[^[:space:]]/) {
                v = $0
                sub(/^[A-Za-z0-9_-]+:[[:space:]]*/, "", v)
                if (v !~ /^[|>]/) {
                    prev_key = $0
                    sub(/:.*$/, "", prev_key)
                }
            }
        }
    ' "$1"
}

SKILL_COMPACTION_MAX_BYTES=20000   # 5,000 tokens x ~4 bytes/token

# Network-call and hidden-behaviour indicators for plugin-installed skills (Discovery).
# Source: the enterprise skill review checklist (platform.claude.com agent-skills/enterprise).
SKILL_NETWORK_RE='(^|[;&|(`[:space:]])(curl|wget)[[:space:]]+[-"'"'"'$h]|(^|[^A-Za-z0-9_.])fetch\(|requests\.(get|post|put|patch|delete|request)\(|urllib\.request|http\.client|(^|[^A-Za-z0-9_])axios[.(]|Invoke-WebRequest|XMLHttpRequest|new WebSocket\(|Invoke-RestMethod|(^|[^A-Za-z0-9_])iwr[[:space:]]|window\.fetch\(|globalThis\.fetch\(|(^|[^A-Za-z0-9_])httpx\.|urlopen\(|(^|[^A-Za-z0-9_.])https?\.get\('
SKILL_HIDDEN_RE='(do not|don.t|never|without) (tell|telling|inform|informing|notify|notifying|mention|mentioning|reveal|revealing)[^.]{0,40}(the )?(user|human)|(hide|conceal)[^.]{0,40}from (the )?(user|human)|ignore (all |any )?(previous|prior|earlier|safety|system)( safety)? (instructions|rules|guidelines)'
# ServerName:tool_name — the snake_case tool segment keeps http:, note:, type:string out.
SKILL_MCP_RE='(^|[^A-Za-z0-9_/:.-])[A-Za-z][A-Za-z0-9_-]*:[a-z][a-z0-9]*(_[a-z0-9]+)+([^A-Za-z0-9_:]|$)'
RULE_DIRECTIVE_RE='(^|[^A-Za-z0-9_])(NEVER|MUST NOT|MUST|ALWAYS|DO NOT)([^A-Za-z0-9_]|$)'

# Body of a SKILL.md / command / rule file: everything after the closing frontmatter ---.
_md_body() {
    awk 'NR == 1 && /^---[[:space:]]*$/ { fm = 1; next } fm == 1 { if ($0 ~ /^---[[:space:]]*$/) fm = 2; next } { print }' "$1"
}

# Body size in bytes (frontmatter excluded).
_skill_body_bytes() {
    _md_body "$1" | wc -c | tr -d '[:space:]'
}

# Lexical path normalisation, pure bash (realpath is not portable to macOS). Splits on /,
# skips "." and empty segments, ".." pops one; never touches the filesystem.
_mhc_lexpath() {
    local seg out=""
    local -a parts=()
    IFS=/ read -ra parts <<< "$1" || true
    for seg in "${parts[@]+"${parts[@]}"}"; do
        case "$seg" in
            ""|.) ;;
            ..) out="${out%/*}" ;;
            *) out="$out/$seg" ;;
        esac
    done
    printf '%s\n' "${out:-/}"
    return 0
}

# Prints a short reason when the frontmatter of $1 cannot parse as YAML, else nothing.
frontmatter_unparsed_reason() {
    awk '
        NR == 1 { if ($0 ~ /^---[[:space:]]*$/) { in_fm = 1; next } else { exit } }
        in_fm && /^---[[:space:]]*$/ { closed = 1; exit }
        in_fm {
            if ($0 ~ /^\t/) { if (reason == "") reason = "tab indentation at frontmatter line " NR; next }
            if ($0 !~ /^([A-Za-z0-9_-]+:|[[:space:]]|#|-[[:space:]]|$)/) { if (reason == "") reason = "line is not a key: value pair at frontmatter line " NR; next }
            if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]+[^[:space:]]/) {
                v = $0; sub(/^[A-Za-z0-9_-]+:[[:space:]]+/, "", v)
                if (v !~ /^["\x27|>\[{&*!%@`#]/) {
                    sub(/[[:space:]]+#.*$/, "", v)
                    if (v ~ /:([[:space:]]|$)/ && reason == "") reason = "unquoted value contains \": \" at frontmatter line " NR
                }
            }
        }
        END { if (in_fm && !closed) reason = "opening --- has no closing ---"; if (reason != "") print reason }
    ' "$1"
}

# Text indicators in one plugin skill / command file: hide-from-user wording, a ../ that
# leaves the plugin, an MCP tool reference. Args: <file> <display> <physical-dir> <physical-root>
_plugin_text_risk() {
    local file="$1" display="$2" dir="$3" root="$4" hid m t mcp
    hid=$(grep -oEi "$SKILL_HIDDEN_RE" "$file" 2>/dev/null | head -1 || true)
    if [ -n "$hid" ]; then
        warning "[SKILL-HIDDEN-BEHAVIOR] $display: says \"$hid\" — instructions to hide actions from the user or override safety rules"
    fi
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        case "$m" in *[A-Za-z0-9_-].) m="${m%.}" ;; esac
        t=$(_mhc_lexpath "$dir/$m")
        if [ "$t" != "$root" ] && [[ "$t" != "$root"/* ]]; then
            warning "[SKILL-HIDDEN-BEHAVIOR] $display: path escapes the plugin: $m — instructions that reach outside the plugin directory"
            break
        fi
    done < <(grep -oE '(\.\./)+[A-Za-z0-9._/-]*' "$file" 2>/dev/null | sort -u || true)
    mcp=$(grep -oE "$SKILL_MCP_RE" "$file" 2>/dev/null | head -1 | sed -E 's/^[^A-Za-z]+//; s/[^a-z0-9]+$//' || true)
    if [ -n "$mcp" ]; then
        warning "[SKILL-MCP-REFERENCE] $display: references MCP tool $mcp — this extends access beyond the skill itself; check that the skill's purpose needs that server"
    fi
    return 0
}

# Bundled scripts of one plugin skill that make network calls. Args: <skill-dir> <display>
_plugin_net_risk() {
    local sd="$1" display="$2" s n
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        # grep -c (not -q): reads the whole stream, so pipefail never sees a SIGPIPE.
        n=$(grep -vE '^[[:space:]]*(#|//)' "$s" 2>/dev/null | grep -cE "$SKILL_NETWORK_RE" || true)
        if [ "${n:-0}" -gt 0 ]; then
            warning "[SKILL-NETWORK-SURFACE] $display: bundled script ${s#"$sd"/} makes network calls (curl/wget/fetch/requests) — review it before trusting this plugin skill"
        fi
    done < <(find -L "$sd" -type f \( -name '*.py' -o -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.ps1' \) -not -path '*/node_modules/*' 2>/dev/null | sort | head -50 || true)
    return 0
}

# Manifest entries (string or array) of <key> in plugin.json, relative and inside the plugin:
# "./x" -> x, "." -> "." ; absolute or ".." entries are skipped (PLUGIN-PATH-ESCAPE territory).
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

# One installed plugin: its skills (default skills/ plus manifest `skills` roots) and commands.
# Args: <plugin-name> <physical-root>
_plugin_skill_risk_scan() {
    local pname="$1" root="$2" e r f sd rel
    local -a files=() cmds=()
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        if [ "$e" = "." ]; then r="$root"; else r="$root/$e"; fi
        [ -d "$r" ] || continue
        for f in "$r"/*/SKILL.md "$r/SKILL.md"; do
            if [ -f "$f" ]; then files+=("$f"); fi
        done
    done < <(printf 'skills\n'; _plugin_manifest_entries "$root" skills)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        sd=$( (cd -P "$(dirname "$f")" 2>/dev/null && pwd -P) || true)
        [ -n "$sd" ] || continue
        if [ "$sd" = "$root" ]; then rel="."; else rel="${sd#"$root"/}"; fi
        _plugin_text_risk "$f" "$pname/$rel/SKILL.md" "$sd" "$root"
        _plugin_net_risk "$sd" "$pname/$rel"
    done < <(printf '%s\n' "${files[@]+"${files[@]}"}" | sort -u || true)
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        r="$root/$e"
        if [ -d "$r" ]; then
            for f in "$r"/*.md; do
                if [ -f "$f" ]; then cmds+=("$f"); fi
            done
        elif [ -f "$r" ]; then
            cmds+=("$r")
        fi
    done < <(printf 'commands\n'; _plugin_manifest_entries "$root" commands)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        sd=$( (cd -P "$(dirname "$f")" 2>/dev/null && pwd -P) || true)
        [ -n "$sd" ] || continue
        if [ "$sd" = "$root" ]; then rel="$(basename "$f")"; else rel="${sd#"$root"/}/$(basename "$f")"; fi
        # Commands are slash-invoked prompts: hide-from-user and MCP reach apply, scripts do not.
        _plugin_text_risk "$f" "$pname/$rel" "$sd" "$root"
    done < <(printf '%s\n' "${cmds[@]+"${cmds[@]}"}" | sort -u || true)
    return 0
}

# Third-party / plugin-installed skills and commands: network surface, hidden behaviour, MCP
# reach (Discovery). User tree only: the user's own skills are exempt, installed plugins are not.
check_plugin_skill_risk() {
    local ip_file="$HOME/.claude/plugins/installed_plugins.json" pname ip root
    [ "$(readlink -f "$CLAUDE_DIR" 2>/dev/null)" = "$(readlink -f "$HOME/.claude" 2>/dev/null)" ] || return 0
    [ -f "$ip_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r pname ip; do
        [ -n "$ip" ] || continue
        root=$( (cd -P "$ip" 2>/dev/null && pwd -P) || true)
        [ -n "$root" ] || continue
        _plugin_skill_risk_scan "$pname" "$root"
    done < <(jq -r '.plugins // {} | to_entries[] | select(.value | type == "array") | select(.value[0] | type == "object") | (.value[0].installPath | strings) as $p | [(.key | sub("@.*$"; "")), $p] | @tsv' "$ip_file" 2>/dev/null || true)
    return 0
}

# A rule scoped with `paths:` is reloaded only on demand after /compact (unscoped rules are
# re-injected from disk), so a hard directive kept only there can vanish from the session.
check_rule_path_lost_on_compact() {
    local rules_dir="$CLAUDE_DIR/rules" rf rel scoped body
    [ -d "$rules_dir" ] || return 0
    while IFS= read -r rf; do
        [ -f "$rf" ] || continue
        scoped=$(awk 'NR == 1 { if ($0 ~ /^---[[:space:]]*$/) { fm = 1; next } else { exit } } fm && /^---[[:space:]]*$/ { exit } fm && /^paths:/ { print "y"; exit }' "$rf" || true)
        [ -n "$scoped" ] || continue
        body=$(_md_body "$rf" || true)
        if grep -qE "$RULE_DIRECTIVE_RE" <<< "$body"; then
            rel=${rf#"$CLAUDE_DIR"/}
            warning "[RULE-PATH-LOST-ON-COMPACT] $rel: a hard directive (NEVER/MUST/ALWAYS/DO NOT) lives in a path-scoped rule — after /compact the rule is reloaded only when a matching file is read again, so the constraint can be absent; move it to CLAUDE.md or an unscoped rule"
        fi
    done < <(find -L "$rules_dir" -name '*.md' -type f 2>/dev/null | sort || true)
    return 0
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

    # Check: frontmatter parses as YAML (orphaned block-sequence class)
    local orphan_key
    orphan_key=$(frontmatter_orphaned_list_key "$skill_file")
    if [ -n "$orphan_key" ]; then
        error "[BAD-FRONTMATTER-SCHEMA] $skill_name: frontmatter is not parseable YAML — a list is indented under the completed scalar '$orphan_key:' (a key line such as when_to_use: is missing above the list); the runtime falls back to the H1 title and the skill loses its routing description"
    fi

    # Check: broader unparsed-YAML reasons (tab indent, unquoted ": ", unclosed ---) —
    # only when the orphaned-list check above did not already report this file.
    local fm_reason
    fm_reason=$(frontmatter_unparsed_reason "$skill_file")
    if [ -n "$fm_reason" ] && [ -z "$orphan_key" ]; then
        error "[BAD-FRONTMATTER-SCHEMA] $skill_name: frontmatter is not parseable YAML ($fm_reason); Claude Code loads the file with no fields set, so the routing description is lost"
    fi

    # Check: body size vs the post-/compact re-injection cap (5,000 tokens per skill)
    local body_bytes
    body_bytes=$(_skill_body_bytes "$skill_file")
    if [ "$body_bytes" -gt "$SKILL_COMPACTION_MAX_BYTES" ]; then
        warning "[SKILL-COMPACTION-TRUNCATED] $skill_name: body is $body_bytes bytes (about $((body_bytes / 4)) tokens) — after /compact only the first 5,000 tokens are re-injected, so put the critical instructions at the top or split to references/"
    fi

    # Check: description present, then length (40 advisory, 1024 hard, 1536 combined)
    desc=$(extract_field "$skill_file" "description")
    when_to_use=$(extract_field "$skill_file" "when_to_use")
    if [ -n "$desc" ]; then
        local desc_len=${#desc}
        # Advisory, not a schema violation: the docs mark description "Recommended"
        # and set no floor, only the 1536-char truncation ceiling. A terse one still
        # triggers, just less reliably. Slash-command files are user-invoked (typed
        # as /name), so a short description there is not even worth mentioning.
        if [ "$is_skill_md" = 1 ] && [ "$desc_len" -lt "$DESC_MIN" ]; then
            warning "[DESC-TOO-SHORT] $skill_name: description is $desc_len chars (under $DESC_MIN — may trigger less reliably)"
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
        # Check: XML-style tags in the description. The docs forbid them: the
        # description is injected into the system prompt. Any bare tag counts,
        # including backticked placeholders such as <iid>.
        if [ "$is_skill_md" = 1 ] && { printf '%s' "$desc" | grep -Eq "$DESC_XML_TAG_RE" || printf '%s' "$desc" | grep -Eq "$DESC_GENERIC_RE"; }; then
            error "[DESC-XML-TAG] $skill_name: description contains an XML-style tag — the docs forbid XML tags in description (it is injected into the system prompt)"
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

    # Check: name field — charset, length
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
    fi
    # Check: reserved skill directory. The docs reserve exactly one name —
    # the folder `synced`, in any capitalization, in the enterprise, personal
    # and project skill locations. It is the directory that is reserved, not
    # the frontmatter name; `anthropic`/`claude` in a name is only a portability
    # hint (RESERVED-WORD-PORTABILITY, below).
    if [ "$is_skill_md" = 1 ]; then
        local dir_lc
        dir_lc=$(printf '%s' "$dir_name" | tr '[:upper:]' '[:lower:]')
        if [ "$dir_lc" = "$RESERVED_SKILL_DIR" ]; then
            error "[RESERVED-NAME] $skill_name: directory '$dir_name' uses the reserved skill folder name '$RESERVED_SKILL_DIR'"
        fi
        # Check: reserved words in the name. Legal in Claude Code, but the Agent
        # Skills API / claude.ai upload rejects names containing anthropic or claude.
        if printf '%s' "$name" | grep -Eiq "$RESERVED_WORD_RE"; then
            warning "[RESERVED-WORD-PORTABILITY] $skill_name: name '$name' contains a reserved word (anthropic/claude) — legal in Claude Code, but rejected when the skill is uploaded to the API or claude.ai"
        fi
        # Check: a bare generic word is not a descriptive skill name.
        if printf '%s' "$name" | grep -Eq "$VAGUE_SKILL_NAME_RE"; then
            warning "[VAGUE-NAME] $skill_name: name '$name' is a generic word — prefer a specific, descriptive name (e.g. processing-pdfs)"
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
    check_over_constrained      "$skill_file" "$skill_name"
    if [ "$is_skill_md" = 1 ]; then
        check_time_and_paths "$skill_file" "$skill_name"
    fi
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

    # Unparseable frontmatter: Claude Code skips a plain agent file and loads a plugin agent
    # with every field ignored.
    local fm_reason
    fm_reason=$(frontmatter_unparsed_reason "$agent_file")
    if [ -z "$fm_reason" ]; then
        fm_reason=$(frontmatter_orphaned_list_key "$agent_file" | sed 's/^\(.\)/a list is indented under the completed scalar \1/')
    fi
    if [ -n "$fm_reason" ]; then
        error "[AGENT-YAML-UNPARSED] $display: frontmatter is not parseable YAML ($fm_reason) — Claude Code reads no fields from the file (a plugin agent still loads, named after the file with every field ignored)"
    fi

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
            [ -n "$(extract_field "$agent_file" "$ff")" ] || continue
            # initialPrompt has no plugin-level equivalent; the others move to the manifest.
            if [ "$ff" = "initialPrompt" ]; then
                warning "[AGENT-PLUGIN-FORBIDDEN-FIELD] $display: plugin agents ignore '$ff' frontmatter (no plugin-level equivalent; remove it)"
            else
                warning "[AGENT-PLUGIN-FORBIDDEN-FIELD] $display: plugin agents ignore '$ff' frontmatter (declare it at plugin level instead)"
            fi
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
    done < <(grep -oE 'npm run [A-Za-z0-9:_-]+.?' "$src" 2>/dev/null | awk '
        {
            tok = $3
            # The token charset stops at a placeholder boundary, leaving a stub that is
            # not a script name: `build:[project]`, `test:*`, `oss|istra:test`, `<app>:start`.
            # The captured trailing character tells us which case we are in.
            if (substr(tok, length(tok), 1) ~ /[][*|<]/) next
            sub(/[^A-Za-z0-9:_-]+$/, "", tok)
            if (tok == "" || tok ~ /:$/) next
            print tok
        }' | sort -u || true)
    # The loop's status is that of its last body command; when the final scanned
    # script is live, `[ "$status" = 1 ]` is false and `set -e` would abort the run.
    return 0
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
        # An imported file is loaded every turn just like its importer, so it is
        # held to the same context-engineering budget.
        case "$resolved" in *.md) check_over_constrained "$resolved" "@$tok" ;; esac
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

# Flag MCP servers Claude Code actually loads (project .mcp.json, user ~/.claude.json)
# that no settings file pre-approves. Claude Code does not read mcpServers from
# settings.json (debug-your-config.md "MCP servers"), so those are never servers here
# (scan-graph reports them as MCP-MISPLACED). The approval set is the union of
# permissions.allow and preApprovedTools over settings.json AND settings.local.json.
check_mcp_preapproved_live() {
    local mcp_file display keys="" strs="" f srv
    command -v jq >/dev/null 2>&1 || return 0
    if [ "$(readlink -f "$CLAUDE_DIR" 2>/dev/null)" = "$(readlink -f "$HOME/.claude" 2>/dev/null)" ]; then
        mcp_file="$HOME/.claude.json"; display=".claude.json"
    else
        mcp_file="$(dirname "$(readlink -f "$CLAUDE_DIR")")/.mcp.json"; display=".mcp.json"
    fi
    [ -f "$mcp_file" ] || return 0
    for f in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
        [ -f "$f" ] || continue
        keys+=$'\n'$(jq -r '(.preApprovedTools // {}) | if type == "object" then keys[] else empty end' "$f" 2>/dev/null || true)
        strs+=$'\n'$(jq -r '((.preApprovedTools // {}) | if type == "object" then .[] | arrays | .[] else empty end), ((.permissions.allow // []) | if type == "array" then .[] else empty end) | strings' "$f" 2>/dev/null || true)
    done
    while IFS= read -r srv; do
        [ -z "$srv" ] && continue
        if printf '%s\n' "$keys" | grep -qxF -- "$srv"; then continue; fi
        if printf '%s\n' "$strs" | grep -qxF -- "mcp__${srv}"; then continue; fi
        case "$strs" in *"mcp__${srv}__"*) continue ;; esac
        error "[MISSING-PRE-APPROVED] $display: MCP server \"$srv\" not in preApprovedTools or permissions.allow"
    done < <(jq -r '(.mcpServers // {}) | if type == "object" then keys[] else empty end' "$mcp_file" 2>/dev/null || true)
    return 0
}

# Flag permission rules Claude Code accepts but never applies.
check_inert_permission_rules() {
    local json_file="$1" display="$2" list kind rule
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r list kind rule; do
        [ -z "$rule" ] && continue
        case "$kind" in
            tool-path)
                warning "[PERM-INERT-RULE] $display: permissions.$list rule '$rule' is never consulted — file permissions are checked against Edit(path) and Read(path) rules only; use Edit(...) in place of Write/NotebookEdit/MultiEdit and Read(...) in place of Glob" ;;
            mcp-parens)
                warning "[PERM-INERT-RULE] $display: permissions.$list rule '$rule' is skipped when the settings file loads — an mcp__ rule cannot carry parentheses; use mcp__server__tool or mcp__server__*" ;;
            primary-param)
                warning "[PERM-INERT-RULE] $display: permissions.$list rule '$rule' is ignored — Tool(param:value) cannot match a tool's primary content field; use Bash(rm *), Read(./path) or WebFetch(domain:host)" ;;
        esac
    done < <(jq -r '
        def inert:
          if test("^(Write|NotebookEdit|Glob|MultiEdit)\\([^)]") and (test("^[A-Za-z]+\\(\\*\\)$") | not) then "tool-path"
          elif test("^mcp__[^(]*\\(") then "mcp-parens"
          elif test("^(Bash|PowerShell)\\([[:space:]]*command[[:space:]]*:|^(Read|Edit|Write)\\([[:space:]]*file_path[[:space:]]*:|^(Grep|Glob)\\([[:space:]]*path[[:space:]]*:|^NotebookEdit\\([[:space:]]*notebook_path[[:space:]]*:|^WebFetch\\([[:space:]]*url[[:space:]]*:") then "primary-param"
          else empty end;
        (.permissions // {}) | if type=="object" then to_entries[] else empty end
        | select(.key | IN("allow","ask","deny")) | .key as $k
        | .value | if type=="array" then .[] else empty end | select(type=="string")
        | . as $r | inert | "\($k)\t\(.)\t\($r)"' "$json_file" 2>/dev/null || true)
    return 0
}

# permissions.md: "If your project has a `.claudeignore` file, it has no effect, so move
# its entries into `Read` deny rules." Project tree only: the user tree is skipped.
check_claudeignore() {
    local root
    [ "$(readlink -f "$CLAUDE_DIR" 2>/dev/null)" = "$(readlink -f "$HOME/.claude" 2>/dev/null)" ] && return 0
    root=$(dirname "$(readlink -f "$CLAUDE_DIR")")
    if [ -f "$root/.claudeignore" ]; then
        warning "[CLAUDEIGNORE-NO-EFFECT] .claudeignore: Claude Code does not read a .claudeignore file — move its entries into permissions.deny Read(...) rules"
    fi
    return 0
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

# Flag `~/.claude/<file>` path citations in auto-memory file BODIES that no longer
# resolve under the user root → MEMORY-STALE-CONTENT (a memory pointing at a script,
# guide, or config that has since been removed/renamed). Only explicit `~/.claude/`
# citations are grounded: they unambiguously target the user root. A bare `.claude/`
# citation in a project memory is project-relative — the project tree may live
# anywhere (including a subdir `.claude/` such as apps/ng/.claude) and is not
# resolvable from here — so bare citations are intentionally skipped to avoid false
# positives. Behaviour-contradiction claims stay judgment (Phase 20). User
# runtime/state subdirs a memory legitimately mentions are skipped.
check_memory_stale_refs() {
    local memf disp p rel cites
    while IFS= read -r memf; do
        [ -f "$memf" ] || continue
        disp="projects/${memf#"$CLAUDE_DIR"/projects/}"
        # shellcheck disable=SC2088  # the "~/.claude/" here is a literal regex matched in the file body, not a path to expand
        cites=$(grep -oE '~/\.claude/[A-Za-z0-9._/-]+\.(md|sh|json|ts|js)' "$memf" 2>/dev/null | sort -u || true)
        [ -z "$cites" ] && continue
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            rel="${p#\~/.claude/}"
            printf '%s' "$rel" | grep -qE '^(projects|plugins|\.?cache|telemetry|usage-data|logs|statsig|todos|shell-snapshots|backups|ide)/|^\.(credentials|claude)' && continue
            [ -f "$(_resolve_dotclaude "$p")" ] || error "[MEMORY-STALE-CONTENT] $disp: cites $p — missing on disk"
        done <<< "$cites"
    done < <(find "$CLAUDE_DIR/projects" -path '*/memory/*.md' 2>/dev/null | sort)
}

# Flag hook matchers Claude Code silently ignores or rejects: an array matcher
# (invalid under any event), a lowercase tool name, or a bare MCP server name.
# The case and bare-MCP checks apply only to the five tool events and only to the
# exact-string path (matcher made of letters, digits, _ - space , |), where
# matching is case-sensitive; any other character makes it a JavaScript regex.
check_hook_matchers() {
    local json_file="$1" display="$2" ev m
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r ev m; do
        [ -z "$ev" ] && continue
        case "$ev" in
            PreToolUse|PermissionRequest)
                error "[HOOK-MATCHER-ARRAY] $display: $ev matcher is a JSON array ($m) — it must be one string such as \"Edit|Write\"; Claude Code rejects the entry and none of this file's other hooks load" ;;
            *)
                error "[HOOK-MATCHER-ARRAY] $display: $ev matcher is a JSON array ($m) — it must be one string such as \"Edit|Write\"; Claude Code lists the entry as an invalid setting and the hook never fires" ;;
        esac
    done < <(jq -r '(.hooks // {}) | if type=="object" then to_entries[] else empty end | .key as $ev | .value | if type=="array" then .[] else empty end | select(type=="object" and ((.matcher|type)=="array")) | "\($ev)\t\(.matcher|tojson)"' "$json_file" 2>/dev/null || true)
    while IFS=$'\t' read -r ev m; do
        [ -z "$ev" ] && continue
        warning "[HOOK-MATCHER-CASE] $display: $ev matcher segment '$m' starts lowercase — tool names are case-sensitive and capitalised (Bash, Edit, Write, Read), so it matches nothing"
    done < <(jq -r '
        (.hooks // {}) | if type=="object" then to_entries[] else empty end
        | select(.key | test("^(PreToolUse|PostToolUse|PostToolUseFailure|PermissionRequest|PermissionDenied)$"))
        | .key as $ev | .value | if type=="array" then .[] else empty end
        | select(type=="object" and ((.matcher|type)=="string"))
        | .matcher as $m | select($m | test("^[A-Za-z0-9_ ,|-]+$"))
        | ($m | split("[|,]"; null) | map(gsub("^ +| +$"; "")) | map(select(test("^[a-z]") and (test("^mcp__") | not))))[]
        | "\($ev)\t\(.)"' "$json_file" 2>/dev/null || true)
    while IFS=$'\t' read -r ev m; do
        [ -z "$ev" ] && continue
        warning "[HOOK-MATCHER-BARE-MCP] $display: $ev matcher segment '$m' names a server but no tool: it is compared as an exact string and matches nothing; write '${m}__.*'"
    done < <(jq -r '
        (.hooks // {}) | if type=="object" then to_entries[] else empty end
        | select(.key | test("^(PreToolUse|PostToolUse|PostToolUseFailure|PermissionRequest|PermissionDenied)$"))
        | .key as $ev | .value | if type=="array" then .[] else empty end
        | select(type=="object" and ((.matcher|type)=="string"))
        | .matcher as $m | select($m | test("^[A-Za-z0-9_ ,|-]+$"))
        | ($m | split("[|,]"; null) | map(gsub("^ +| +$"; "")) | map(select(startswith("mcp__") and (ltrimstr("mcp__") | contains("__") | not))))[]
        | "\($ev)\t\(.)"' "$json_file" 2>/dev/null || true)
    return 0
}

# Flag hook timeouts above 2x the documented default. command/http/mcp_tool 600s
# (30s on UserPromptSubmit, PreModelSwitch, PostModelSwitch; 10s on
# MessageDisplay), prompt 30s, agent 60s. SessionEnd hooks share a budget Claude
# Code raises to the longest per-hook timeout, up to 60s, so they are capped.
check_hook_timeouts() {
    local json_file="$1" display="$2" ev typ t def
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r ev typ t; do
        case "${t:-}" in ''|*[!0-9]*) continue ;; esac
        if [ "$ev" = "SessionEnd" ]; then
            [ "$t" -gt "$HOOK_TIMEOUT_SESSIONEND_CAP" ] && warning "[SUSPICIOUS-TIMEOUT] $display: a $typ hook (SessionEnd) has timeout ${t}s — SessionEnd shares a budget Claude Code raises to the highest per-hook timeout only up to ${HOOK_TIMEOUT_SESSIONEND_CAP}s"
            continue
        fi
        case "$typ" in
            command|http|mcp_tool)
                case "$ev" in
                    UserPromptSubmit|PreModelSwitch|PostModelSwitch) def=$HOOK_TIMEOUT_FAST_EVENT ;;
                    MessageDisplay)                                  def=$HOOK_TIMEOUT_MESSAGEDISPLAY ;;
                    *)                                               def=$HOOK_TIMEOUT_COMMAND ;;
                esac ;;
            prompt) def=$HOOK_TIMEOUT_PROMPT ;;
            agent)  def=$HOOK_TIMEOUT_AGENT ;;
            *) continue ;;
        esac
        if [ "$t" -gt $((def * 2)) ]; then
            warning "[SUSPICIOUS-TIMEOUT] $display: a $typ hook ($ev) has timeout ${t}s (>2x the ${def}s default)"
        fi
    done < <(jq -r '.hooks // {} | to_entries[] | select(.value|type=="array") | .key as $ev | .value[] | select(type=="object") | (.hooks // [])[]? | select(type=="object" and has("type") and ((.timeout|type)=="number") and ((.type=="command" and .async==true and .asyncRewake!=true)|not)) | "\($ev)\t\(.type)\t\(.timeout)"' "$json_file" 2>/dev/null || true)
    return 0
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

# Flag http hooks that no allowedHttpHookUrls pattern matches. Claude Code blocks
# such a hook outright, so it never runs and never reports an error.
check_http_hook_allowlist() {
    local json_file="$1" display="$2" url matched pat
    [ "$HTTP_URL_ALLOWLIST_SET" -eq 1 ] || return 0
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        matched=0
        while IFS= read -r pat; do
            [ -z "$pat" ] && continue
            # the allowlist entry IS a glob (* is the documented wildcard): stripping the whole
            # URL with it leaves nothing exactly when it matches
            [ -z "${url##$pat}" ] && { matched=1; break; }
        done <<<"$HTTP_URL_ALLOWLIST"
        [ "$matched" -eq 1 ] && continue
        warning "[HOOK-HTTP-BLOCKED] $display: http hook url '$url' matches no allowedHttpHookUrls pattern — Claude Code blocks it, so the hook never runs"
    done < <(jq -r '(.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | select(.type == "http") | (.url // empty)' "$json_file" 2>/dev/null || true)
}

# Flag settings keys that broadly loosen the permission sandbox. bypassPermissions
# auto-approves every tool call; enableAllProjectMcpServers trusts any project
# .mcp.json without review; sandbox.disabled drops the filesystem/network sandbox;
# a wildcard autoMode.allow entry hands auto mode a whole tool. All are valid keys —
# the finding is the risk, not a schema error.
check_settings_security() {
    local json_file="$1" display="$2" mode broad
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    mode=$(jq -r '(if type == "object" then ((.permissions | if type == "object" then .defaultMode else null end) // .defaultMode) else null end) | strings' "$json_file" 2>/dev/null || true)
    if [ "$mode" = "bypassPermissions" ]; then
        # Since v2.1.257 only user or managed settings can switch it on.
        if [ "$(_settings_file_scope "$json_file")" = "user" ]; then
            error "[SETTINGS-BYPASS-MODE] $display: defaultMode is \"bypassPermissions\" — every tool call is auto-approved with no prompt"
        else
            warning "[SETTINGS-BYPASS-MODE] $display: defaultMode \"bypassPermissions\" in a project or local file is ignored since v2.1.257 (the session starts in Manual mode) — set it in user or managed settings, or pass --permission-mode"
        fi
    fi
    if [ "$(jq -r '.enableAllProjectMcpServers // false' "$json_file" 2>/dev/null)" = "true" ]; then
        warning "[SETTINGS-MCP-AUTOAPPROVE] $display: enableAllProjectMcpServers is true — every project MCP server is trusted without review"
    fi
    if [ "$(jq -r '.sandbox.disabled // false' "$json_file" 2>/dev/null)" = "true" ]; then
        warning "[SETTINGS-SANDBOX-OFF] $display: sandbox.disabled is true — tool calls run unsandboxed with full filesystem and network access"
    fi
    # autoMode is a user-or-managed key: a project/local autoMode.allow is inert
    if [ "$(_settings_file_scope "$json_file")" = "user" ] && [ "$(jq -r '.permissions.disableAutoMode // false' "$json_file" 2>/dev/null)" != "true" ]; then
        broad=$(jq -r '(.autoMode.allow // []) | if type=="array" then .[] else empty end' "$json_file" 2>/dev/null \
                | grep -xE '\*|Bash|Bash\(\*\)' | head -1 || true)
        if [ -n "$broad" ]; then
            warning "[SETTINGS-AUTOMODE-BROAD] $display: autoMode.allow contains '$broad' — auto mode then runs every matching command with no prompt"
        fi
    fi
}

# --- settings scope (source: settings-reference "Scope" column; refresh recipe in
# references/permission-hygiene.md "Settings scope table") -----------------------
# Dotted entries are nested paths. A parent already listed makes its children redundant.
# Scope "Managed": ignored in user, project and local files (38 keys + the alias allowedMarketplaces = 39 entries)
SETTINGS_KEYS_MANAGED_ONLY=(allowAllClaudeAiMcps allowClaudeInChromeWithManagedMcp allowedChannelPlugins allowedProviders allowManagedHooksOnly allowManagedMcpServersOnly allowManagedPermissionRulesOnly availableModelsMatch blockedMarketplaces browserExternalPageTools channelsEnabled claudeMd deniedModels disableBrowserExternalNavigation disableCommandPluginSources disableDesktopLocalSessions disableMobileSimulatorTools disableSideloadFlags forceLoginGatewayUrl forceRemoteSettingsRefresh gatewayInternalNetworks managedMcpServers managedSourcesBehavior modelPricing parentSettingsBehavior pluginSuggestionMarketplaces pluginTrustMessage policyHelper requiredMaximumVersion requiredMinimumVersion sandbox.bwrapPath sandbox.filesystem.allowManagedReadPathsOnly sandbox.network.allowManagedDomainsOnly sandbox.socatPath sshHostAllowlist strictKnownMarketplaces allowedMarketplaces strictPluginOnlyCustomization wslInheritsWindowsSettings)
# Scope "User or managed": ignored in project and local files (25)
SETTINGS_KEYS_USER_OR_MANAGED=(askUserQuestionTimeout appendPlugins autoContinueAtUsageLimit autoMode bashEditDiffEnabled desktopSessionCleanupPeriodDays dialogExpiry feedbackDrafts footerLinksRegexes modelPicker pluginConfigs prependPlugins processWrapper sandbox.allowAppleEvents sandbox.credentials.allowPlaintextInject sandbox.credentials.awsPairs sandbox.credentials.sigv4 sandbox.filesystem.disabled sandbox.network.strictAllowlist sandbox.network.tlsTerminate sandbox.ripgrep skipAutoPermissionPrompt spellcheck sshConfigs vimInsertModeRemaps)
# Scope "User, local, or managed": ignored in project files only (4)
SETTINGS_KEYS_USER_LOCAL_MANAGED=(skipDangerousModePermissionPrompt syncClaudeAiPlugins syncClaudeAiSkills useAutoModeDuringPlan)
# env variables (matched on the NAME) that project and local settings may not set
SETTINGS_ENV_DROPPED_PROJECT_RE='^(CLAUDE_CONFIG_DIR|CLAUDE_CODE_TMPDIR|HOME|TMPDIR|TMP|TEMP|XDG_[A-Z0-9_]+|OTEL_LOG_RAW_API_BODIES|ENABLE_BETA_TRACING_DETAILED|BETA_TRACING_ENDPOINT|CLAUDE_CODE_ENABLE_TELEMETRY|CLAUDE_CODE_ENHANCED_TELEMETRY_BETA|ENABLE_ENHANCED_TELEMETRY_BETA|OTEL_(LOGS|METRICS|TRACES)_EXPORTER|OTEL_LOG_(USER_PROMPTS|ASSISTANT_RESPONSES|TOOL_CONTENT|TOOL_DETAILS)|OTEL_EXPORTER_OTLP(_[A-Z0-9]+)*_(ENDPOINT|HEADERS|PROTOCOL|CERTIFICATE|CLIENT_KEY|INSECURE)|OTEL_EXPORTER_PROMETHEUS_(HOST|PORT)|CLAUDE_CODE_PROCESS_WRAPPER|CLAUDE_CODE_SYNC_SKILLS|CLAUDE_CODE_SYNC_PLUGINS|CLAUDE_CODE_PLUGIN_CACHE_DIR|CLAUDE_CODE_PLUGIN_SEED_DIR)$'
# Windows variable names are case-insensitive: matched with grep -i
SETTINGS_ENV_DROPPED_WINDOWS_RE='^(SystemRoot|ComSpec|ProgramData|LOCALAPPDATA|PATHEXT|PSModulePath|ProgramFiles([A-Za-z0-9()]*)?)$'
# ignored from EVERY settings file (user too)
SETTINGS_ENV_DROPPED_ALL_RE='^(CLAUDE_CODE_REMOTE|CLAUDE_CODE_ACCOUNT_UUID|CLAUDE_CODE_MESSAGING_SOCKET|CLAUDE_CODE_MESSAGING_TOKEN|CLAUDE_CODE_PROJECT_DIR_NAME|CLAUDE_CODE_RESTRICTED|CLAUDE_CODE_DISABLE_POWERSHELL_CMD_RM_DENY|CLAUDE_CODE_DISABLE_DANGEROUS_RM_TIMEOUT|CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT|CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT)$'
# The only values project/local settings may still set, because they turn something off
# (settings-reference "Variables Claude Code ignores in env"; env-vars.md defines off):
# the three exporter selectors accept exactly `none`; the three OTEL_LOG_* accept 0/false/no/off in any casing.
SETTINGS_ENV_EXPORTER_RE='^OTEL_(LOGS|METRICS|TRACES)_EXPORTER$'
SETTINGS_ENV_LOG_RE='^OTEL_LOG_(USER_PROMPTS|TOOL_CONTENT|TOOL_DETAILS)$'
# Keys that no longer do anything: key<TAB>message, checked in every settings file
SETTINGS_KEYS_REMOVED='includeCoAuthoredBy	deprecated since v2.0.62 — use attribution (attribution.commit / attribution.pr)
disableArtifact	deprecated — use enableArtifact (enableArtifact: false replaces disableArtifact: true)
keybindingFlavor	deprecated since v2.1.261 and has no effect — remove it
voiceEnabled	deprecated since v2.1.92 — use voice.enabled
permissionExplainerEnabled	removed in v2.1.257 and has no effect — remove it
taskOutputMaxChars	removed in v2.1.277 and has no effect — remove it
teammateDefaultModel	removed in v2.1.234 and has no effect — remove it'
# Of those, the "Global config" keys also live in ~/.claude.json
SETTINGS_KEYS_GLOBAL_CONFIG_REMOVED=(permissionExplainerEnabled teammateDefaultModel)

# user | project | local — how the file relates to the tree being audited.
_settings_file_scope() {
    local f="$1"
    if [ "$(readlink -f "$(dirname "$f")" 2>/dev/null)" = "$(readlink -f "$HOME/.claude" 2>/dev/null)" ]; then
        echo user
    elif [ "$(basename "$f")" = "settings.local.json" ]; then
        echo local
    else
        echo project
    fi
    return 0
}

# Warn for each dotted key of the given list present in a settings file.
_settings_scan_keys() { # <file> <display> <scope> <allowed-from label> <key>...
    local json_file="$1" display="$2" scope="$3" from="$4" k
    shift 4
    for k in "$@"; do
        if jq -e --arg k "$k" 'getpath($k | split(".")) != null' "$json_file" >/dev/null 2>&1; then
            warning "[SETTINGS-SCOPE-IGNORED] $display: '$k' is ignored in $scope settings — Claude Code reads it only from $from"
        fi
    done
    return 0
}

check_settings_scope_ignored() {
    local json_file="$1" display="$2" scope ev val
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    scope=$(_settings_file_scope "$json_file")
    _settings_scan_keys "$json_file" "$display" "$scope" "managed settings" "${SETTINGS_KEYS_MANAGED_ONLY[@]}"
    if [ "$scope" != user ]; then _settings_scan_keys "$json_file" "$display" "$scope" "user or managed settings" "${SETTINGS_KEYS_USER_OR_MANAGED[@]}"; fi
    if [ "$scope" = project ]; then _settings_scan_keys "$json_file" "$display" "$scope" "user, local or managed settings" "${SETTINGS_KEYS_USER_LOCAL_MANAGED[@]}"; fi
    # env: variables a checked-out repository may not set (project/local) or nobody may set (all).
    # Tab/newline in a value would forge extra records, and a key outside the identifier
    # alphabet (parentheses allowed for ProgramFiles(x86)) is not a variable name at all.
    while IFS=$'\t' read -r ev val; do
        [ -z "$ev" ] && continue
        if printf '%s' "$ev" | grep -qE "$SETTINGS_ENV_DROPPED_ALL_RE"; then
            warning "[SETTINGS-SCOPE-IGNORED] $display: env.$ev is ignored in every settings file — Claude Code reads it from its launch environment only"
        elif [ "$scope" != user ] && { printf '%s' "$ev" | grep -qE "$SETTINGS_ENV_DROPPED_PROJECT_RE" || printf '%s' "$ev" | grep -qiE "$SETTINGS_ENV_DROPPED_WINDOWS_RE"; }; then
            if printf '%s' "$ev" | grep -qE "$SETTINGS_ENV_EXPORTER_RE" && [ "$val" = "none" ]; then
                continue
            fi
            if printf '%s' "$ev" | grep -qE "$SETTINGS_ENV_LOG_RE" && printf '%s' "$val" | grep -qiE '^(0|false|no|off)$'; then
                continue
            fi
            warning "[SETTINGS-SCOPE-IGNORED] $display: env.$ev is dropped in $scope settings — set it in user or managed settings instead"
        fi
    done < <(jq -r '(.env // {}) | if type=="object" then to_entries[] | select(.key | test("^[A-Za-z_][A-Za-z0-9_()]*$")) | "\(.key)\t\(.value|tostring|gsub("[\\n\\r\\t]";" "))" else empty end' "$json_file" 2>/dev/null || true)
    # defaultMode auto only counts from user/managed (bypassPermissions: see check_settings_security)
    if [ "$scope" != user ]; then
        val=$(jq -r '(.permissions.defaultMode // .defaultMode) // empty' "$json_file" 2>/dev/null || true)
        if [ "$val" = "auto" ]; then
            warning "[SETTINGS-SCOPE-IGNORED] $display: defaultMode \"auto\" does not take effect from $scope settings — set it in ~/.claude/settings.json"
        fi
    fi
    return 0
}

# --- deprecated / removed keys --------------------------------------------
check_settings_deprecated_keys() {
    local json_file="$1" display="$2" k msg
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r k msg; do
        if jq -e --arg k "$k" 'has($k)' "$json_file" >/dev/null 2>&1; then
            warning "[SETTINGS-DEPRECATED-KEY] $display: '$k' is $msg"
        fi
    done <<<"$SETTINGS_KEYS_REMOVED"
    return 0
}

# The "Global config" keys live in ~/.claude.json, which is not a settings file: look
# there too, user tree only (the only tree that reads it).
check_global_config_removed() {
    local gc="$HOME/.claude.json" k msg
    [ -f "$gc" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    [ "$(readlink -f "$CLAUDE_DIR" 2>/dev/null)" = "$(readlink -f "$HOME/.claude" 2>/dev/null)" ] || return 0
    while IFS=$'\t' read -r k msg; do
        case " ${SETTINGS_KEYS_GLOBAL_CONFIG_REMOVED[*]} " in *" $k "*) ;; *) continue ;; esac
        if jq -e --arg k "$k" 'has($k)' "$gc" >/dev/null 2>&1; then
            warning "[SETTINGS-DEPRECATED-KEY] .claude.json: '$k' is $msg"
        fi
    done <<<"$SETTINGS_KEYS_REMOVED"
    return 0
}

# --- claudeMdExcludes -----------------------------------------------------
# Patterns match absolute paths (memory.md); no tilde expansion is documented, so only
# `/...` and `**...` are anchored. `**`-leading / absolute globs must also be able to match
# some CLAUDE.md on disk (project/local files only: a user-scope exclude may target another repo).
check_claudemd_excludes() {
    local json_file="$1" display="$2" pat scope root cand d hit have_cands=0
    local -a cands=()
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    scope=$(_settings_file_scope "$json_file")
    while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        case "$pat" in
            /*|'**'*) ;;
            *) warning "[CLAUDEMD-EXCLUDE-DEAD] $display: claudeMdExcludes pattern '$pat' is relative — patterns match absolute paths, so it never matches (prefix it with **/)"; continue ;;
        esac
        case "$pat" in
            *[\*\?\[]*)
                [ "$scope" = user ] && continue
                # brace expansion is not evaluated here: skip rather than guess
                case "$pat" in *'{'*) continue ;; esac
                if [ "$have_cands" -eq 0 ]; then
                    have_cands=1
                    root=$(git -C "$(dirname "$CLAUDE_DIR")" rev-parse --show-toplevel 2>/dev/null || true)
                    [ -n "$root" ] || root=$(dirname "$CLAUDE_DIR")
                    while IFS= read -r cand; do
                        [ -n "$cand" ] && cands+=("$cand")
                    done < <(find "$root" -maxdepth 8 \( -name node_modules -o -name .git \) -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md -o -name AGENTS.md -o \( -path '*/.claude/rules/*' -name '*.md' \) \) -type f -print 2>/dev/null || true)
                    d=$(cd "$root" 2>/dev/null && pwd -P || true)
                    while [ -n "$d" ] && [ "$d" != "/" ]; do
                        for cand in "$d/CLAUDE.md" "$d/CLAUDE.local.md" "$d/AGENTS.md" "$d/.claude/CLAUDE.md" "$d/.claude/AGENTS.md"; do
                            [ -f "$cand" ] && cands+=("$cand")
                        done
                        d=$(dirname "$d")
                    done
                    [ -f "/CLAUDE.md" ] && cands+=("/CLAUDE.md")
                    for cand in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/AGENTS.md"; do
                        [ -f "$cand" ] && cands+=("$cand")
                    done
                    while IFS= read -r cand; do
                        [ -n "$cand" ] && cands+=("$cand")
                    done < <(find "$HOME/.claude/rules" -type f -name '*.md' 2>/dev/null || true)
                fi
                # bash `==` lets `*` cross `/`: deliberately more permissive than the real glob,
                # so a warning means no file could match
                hit=0
                for cand in ${cands[@]+"${cands[@]}"}; do
                    # the longest-prefix strip leaves nothing only when the whole path matches the glob
                    if [ -z "${cand##$pat}" ]; then hit=1; break; fi
                done
                [ "$hit" -eq 1 ] || warning "[CLAUDEMD-EXCLUDE-DEAD] $display: claudeMdExcludes pattern '$pat' matches no CLAUDE.md or other instruction file on disk (CLAUDE.local.md, AGENTS.md, .claude/rules/**/*.md)"
                ;;
            *)
                [ -e "$pat" ] || warning "[CLAUDEMD-EXCLUDE-DEAD] $display: claudeMdExcludes path '$pat' does not exist on disk"
                ;;
        esac
    done < <(jq -r '(.claudeMdExcludes // []) | if type=="array" then .[] else empty end | select(type=="string")' "$json_file" 2>/dev/null || true)
    return 0
}

# --- worktree.sparsePaths -------------------------------------------------
# sparsePaths entries are repo-root-relative (large-codebases.md). A sparse worktree checks
# out only the listed directories plus root-level files, so a committed repo-root .claude/
# vanishes unless listed. Only the tree the worktree actually reads is judged: the repo-root
# .claude, and only when it is committed.
check_worktree_sparse() {
    local json_file="$1" display="$2" root has_claude
    [ -f "$json_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    [ "$(_settings_file_scope "$json_file")" = user ] && return 0
    jq -e '(.worktree.sparsePaths // []) | type == "array" and length > 0' "$json_file" >/dev/null 2>&1 || return 0
    root=$(git -C "$(dirname "$CLAUDE_DIR")" rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$root" ] || return 0
    [ "$(readlink -f "$CLAUDE_DIR" 2>/dev/null)" = "$(readlink -f "$root/.claude" 2>/dev/null)" ] || return 0
    [ -n "$(git -C "$root" ls-files -- .claude 2>/dev/null | head -n 1 || true)" ] || return 0
    has_claude=$(jq -r '[.worktree.sparsePaths[] | select(type=="string") | sub("^\\./";"") | sub("/+$";"")] | any(. == ".claude")' "$json_file" 2>/dev/null || echo false)
    if [ "$has_claude" != "true" ]; then
        warning "[WORKTREE-SPARSE-NO-CLAUDE] $display: worktree.sparsePaths omits '.claude': sparse worktrees check out only the listed directories plus root-level files, so the committed .claude/settings.json and .claude/rules/ are missing there (large-codebases: include .claude in the list); untracked skills, agents and commands are still read through from the main checkout"
    fi
    return 0
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

# Print a markdown file's body: frontmatter and fenced code blocks removed, so
# prose metrics are not skewed by YAML keys or shell samples.
_body_stream() {
    awk '
        NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
        fm { if (/^---[[:space:]]*$/) fm = 0; next }
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        { print }
    ' "$1" 2>/dev/null
}

# Print `NR:text` for prose lines only (line numbers kept, unlike _body_stream).
# Mode `fence`: skip frontmatter and fenced code (``` and ~~~). Mode `full`: also
# skip <details> blocks (a single-line <details>...</details> is skipped without
# setting the flag) and Old patterns / legacy / deprecated sections, which end at
# the next heading of the same or a higher level.
_prose_lines() {
    awk -v mode="$2" '
        NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
        fm { if (/^---[[:space:]]*$/) fm = 0; next }
        /^[[:space:]]*(```|~~~)/ {
            # CommonMark: a fence closes only on the same character, at least as
            # long as the opener, with nothing but whitespace after the run.
            ln = $0; sub(/^[[:space:]]+/, "", ln)
            ch = substr(ln, 1, 1); n = 0
            while (substr(ln, n + 1, 1) == ch) n++
            if (!fence) { fence = 1; fch = ch; flen = n }
            else if (ch == fch && n >= flen && substr(ln, n + 1) ~ /^[[:space:]]*$/) fence = 0
            next
        }
        fence { next }
        mode == "full" {
            if (/^#+[[:space:]]/) {
                match($0, /^#+/); lvl = RLENGTH
                if (legacy && lvl <= legacy_lvl) legacy = 0
                if (!legacy && tolower($0) ~ /^#+ +(old patterns?|legacy|deprecated)([^a-z0-9_-]|$)/) {
                    legacy = 1; legacy_lvl = lvl
                }
            }
            if (legacy) next
            if (/^[[:space:]]*<details/ && /<\/details>/) next
            if (/^[[:space:]]*<details/) { det = 1; next }
            if (/<\/details>/) { det = 0; next }
            if (det) next
        }
        { print NR ":" $0 }
    ' "$1" 2>/dev/null
}

# Flag backslash paths (WINDOWS-PATH) and date-conditioned wording (TIME-SENSITIVE)
# in a skill's prose: SKILL.md and its references. One finding per file per tag.
check_time_and_paths() {
    local file="$1" display="$2" hit
    [ -f "$file" ] || return 0
    # Regex escapes (`doc\d.md`, `^v\d\.json$`) are not paths: strip \d \w \s \b (and
    # upper-case forms) when not followed by an alphanumeric (`scripts\build.py` stays
    # a path), and `\.`, before matching.
    hit=$(_prose_lines "$file" fence \
          | sed -E ':a;s/\\[dwsbDWSB]([^A-Za-z0-9]|$)/\1/;ta;s/\\\././g' \
          | grep -E "$WINDOWS_PATH_RE" | head -1 || true)
    if [ -n "$hit" ]; then
        warning "[WINDOWS-PATH] $display: Windows-style backslash path at line ${hit%%:*} — use forward slashes (scripts/helper.py)"
    fi
    hit=$(_prose_lines "$file" full | grep -Ei "$TIME_SENSITIVE_RE" | head -1 || true)
    if [ -n "$hit" ]; then
        warning "[TIME-SENSITIVE] $display: date-conditioned wording at line ${hit%%:*} — it will rot; move legacy behaviour under an 'Old patterns' section"
    fi
    return 0
}

# Flag instruction files whose prose is mostly hard rules. Newer models resolve
# intent from context; a wall of shouted absolutes forces them to arbitrate
# conflicting constraints before working, and the guardrails that once earned
# their tokens now cost quality.
check_over_constrained() {
    local file="$1" display="$2" body_lines hits per100
    [ -f "$file" ] || return 0
    body_lines=$(_body_stream "$file" | grep -c '' || true)
    if [ "${body_lines:-0}" -lt "$OVERCONSTRAINT_MIN_BODY" ]; then
        return 0
    fi
    hits=$(_body_stream "$file" | grep -oE "$ABSOLUTE_DIRECTIVE_RE" | grep -c '' || true)
    if [ "${hits:-0}" -lt "$OVERCONSTRAINT_MIN_HITS" ]; then
        return 0
    fi
    per100=$(( hits * 100 / body_lines ))
    if [ "$per100" -ge "$OVERCONSTRAINT_PER_100" ]; then
        warning "[OVER-CONSTRAINED] $display: $hits absolute directives over $body_lines body lines ($per100 per 100) — let the model use judgement; keep hard rules for the safety-critical few"
    fi
}

# Print the normalized directive lines of a markdown file: lowercased, list
# markers / emphasis / trailing punctuation stripped, short lines and
# non-instructions dropped. Two files carrying the same normalized line are
# stating the same rule twice.
_directive_lines() {
    _body_stream "$1" | awk -v min="$DUPLICATED_INSTRUCTION_MIN_CHARS" '
        {
            s = tolower($0)
            sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]*/, "", s)
            sub(/^[[:space:]]*#+[[:space:]]*/, "", s)
            gsub(/[`*_>]/, "", s)
            gsub(/[[:space:]]+/, " ", s)
            sub(/^ /, "", s); sub(/ $/, "", s)
            sub(/[.;:,!]+$/, "", s)
            if (length(s) < min) next
            if (s !~ /(^| )(must|never|always|do not|don.t|required|forbidden|prohibited)( |$)/) next
            print s
        }
    ' | sort -u
}

# Flag a directive stated verbatim in more than one context file. Repetition was
# a workaround for older models weighting the end of the context window; today it
# just spends tokens twice and drifts when only one copy is updated.
check_instruction_duplication() {
    local tmp f disp line n where snippet
    tmp=$(mktemp) || return 0
    for f in "$CLAUDE_MD" "$CLAUDE_DIR/CLAUDE.local.md" "$CLAUDE_DIR/../CLAUDE.local.md" \
             "$CLAUDE_DIR"/rules/*.md "$SKILLS_DIR"/*/SKILL.md "$COMMANDS_DIR"/*.md; do
        [ -f "$f" ] || continue
        case "$f" in
            "$CLAUDE_DIR/../"*) disp=$(basename "$f") ;;
            "$CLAUDE_DIR/"*)    disp=${f#"$CLAUDE_DIR"/} ;;
            *)                  disp=$(basename "$f") ;;
        esac
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            printf '%s\t%s\n' "$line" "$disp" >> "$tmp"
        done < <(_directive_lines "$f")
    done
    while IFS=$'\t' read -r n where snippet; do
        [ -z "$n" ] && continue
        [ "${#snippet}" -gt 60 ] && snippet="${snippet:0:57}..."
        warning "[INSTRUCTION-DUPLICATED] $where: same directive stated in $n files — \"$snippet\" — say it once, in the file that owns the topic"
    done < <(awk -F'\t' '
        !seen[$1 SUBSEP $2]++ {
            n[$1]++
            where[$1] = (where[$1] == "" ? $2 : where[$1] " + " $2)
        }
        END { for (k in n) if (n[k] > 1) printf "%d\t%s\t%s\n", n[k], where[k], k }
    ' "$tmp" 2>/dev/null | sort -rn | head -5 || true)
    rm -f "$tmp"
}

# Flag a CLAUDE.md block that just lists the file tree. A directory dump is
# something a session reads off the file system in one call; the context budget
# is better spent on the gotchas it cannot infer.
check_claudemd_obvious() {
    local file="$1" display="$2" root names start count toks tok matched
    [ -f "$file" ] || return 0
    root=$(dirname "$file")
    names=""
    while IFS=$'\t' read -r start count toks; do
        [ -z "$start" ] && continue
        if [ -z "$names" ]; then
            names=$(find "$root" -maxdepth 3 -name .git -prune -o -print 2>/dev/null \
                    | awk -F/ '{ print $NF }' | sort -u || true)
        fi
        matched=0
        for tok in $toks; do
            tok="${tok%/}"
            if [ -e "$root/$tok" ] || printf '%s\n' "$names" | grep -qxF "$tok"; then
                matched=$((matched + 1))
            fi
        done
        if [ "$matched" -ge "$OBVIOUS_LISTING_MIN_RESOLVED" ]; then
            warning "[CLAUDEMD-OBVIOUS] $display:$start — $count consecutive path lines ($matched resolve on disk); the file tree is already visible to a session, spend the budget on gotchas"
            return 0
        fi
    done < <(awk -v min="$OBVIOUS_LISTING_MIN_LINES" '
        function flush(   i, s) {
            if (n >= min) {
                s = ""
                for (i = 1; i <= n; i++) s = s (i > 1 ? " " : "") tok[i]
                printf "%d\t%d\t%s\n", start, n, s
            }
            n = 0
        }
        NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
        fm { if (/^---[[:space:]]*$/) fm = 0; next }
        {
            s = $0
            gsub(/[^ -~]/, " ", s)
            sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]*/, "", s)
            gsub(/[`"'"'"']/, "", s)
            sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
            if (s ~ /^[A-Za-z0-9._@-]+(\/[A-Za-z0-9._@-]+)*\/?$/ && s ~ /[A-Za-z0-9]/) {
                if (n == 0) start = NR
                tok[++n] = s
                next
            }
            flush()
        }
        END { flush() }
    ' "$file" 2>/dev/null || true)
}

# Flag session facts parked in CLAUDE.md. Auto-memory now owns "what I learned
# about this user / this run"; the same content in CLAUDE.md reloads every turn
# and goes stale silently.
check_claudemd_memory_drift() {
    local file="$1" display="$2" n first
    [ -f "$file" ] || return 0
    IFS=$'\t' read -r n first < <(awk '
        NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
        fm { if (/^---[[:space:]]*$/) fm = 0; next }
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        /^[[:space:]]*#{1,6}[[:space:]]/ {
            h = tolower($0)
            inmem = (h ~ /(memor(y|ies)|notes? to self|learned|session notes)/) ? 1 : 0
            next
        }
        /^[[:space:]]*[-*+][[:space:]]/ {
            b = tolower($0)
            sub(/^[[:space:]]*[-*+][[:space:]]*/, "", b)
            if (inmem || b ~ /^(remember\b|note to self\b|reminder:|(the )?user (prefers|likes|wants|asked|said)\b)/) {
                n++
                if (first == 0) first = NR
            }
        }
        END { printf "%d\t%d\n", n, first }
    ' "$file" 2>/dev/null || true)
    if [ "${n:-0}" -ge "$MEMORY_DRIFT_MIN_BULLETS" ]; then
        warning "[CLAUDEMD-MEMORY-DRIFT] $display: $n memory-shaped facts (first at line $first) — auto-memory keeps these out of every-turn context"
    fi
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

# Detect skills whose stated (or entire) vocabulary offers no anchor a model
# can use to disambiguate them from siblings — the coder_eval study's leading
# cause of silent skill non-activation. Standalone pass over SKILLS_DIR built
# on the check_name_collisions() pattern: its own walk, SKILLS_DIR_EXCLUDES
# honoured, flat sorted lists + sort|uniq -c for ownership, no associative
# arrays. Also backs `--anchors`: same extraction, JSON instead of findings —
# branches on ANCHORS_ONLY so the corpus is only walked once.
check_anchor_analysis() {
    local d name skip ex file desc when_to_use text tokens
    local skill_names=() skill_tokens=() skill_texts=()
    if [ -d "$SKILLS_DIR" ]; then
        for d in "$SKILLS_DIR"/*/; do
            [ -d "$d" ] || continue
            name=$(basename "$d"); skip=0
            for ex in "${SKILLS_DIR_EXCLUDES[@]}"; do [ "$name" = "$ex" ] && skip=1 && break; done
            [ "$skip" = 1 ] && continue
            file="$d/SKILL.md"
            [ -f "$file" ] || continue
            desc=$(extract_field "$file" "description")
            when_to_use=$(extract_field "$file" "when_to_use")
            text="$desc $when_to_use"
            tokens=$(anchor_tokens_from "$text")
            skill_names+=("$name")
            skill_tokens+=("$tokens")
            skill_texts+=("$text")
        done
    fi

    if [ "${#skill_names[@]}" -eq 0 ]; then
        [ "$ANCHORS_ONLY" = 1 ] && printf '{}\n'
        return 0
    fi

    # Flat (skill,token) pairs -> owner-count per token. Each skill's own
    # token list is already deduped (anchor_tokens_from sorts -u), so counting
    # occurrences across the flattened list IS the distinct-skill count.
    local i pairs owner_counts
    pairs=""
    for i in "${!skill_names[@]}"; do
        [ -z "${skill_tokens[$i]}" ] && continue
        pairs="${pairs}${skill_tokens[$i]}"$'\n'
    done
    # uniq -c's own output ("  N token text") is itself whitespace-delimited,
    # so a multi-word token (`mvn clean install`) would smear across $2..$N
    # if read back with a bare field split. The sed below anchors ONLY on the
    # leading run it just added (spaces + digits + spaces) and replaces it
    # with a single TAB — the token's own internal spaces, whatever they are,
    # are never touched. Ownership is then queried with `awk -F'\t'`, so the
    # token is compared as one whole field, never split on whitespace.
    owner_counts=$(printf '%s\n' "$pairs" | grep -v '^$' | sort | uniq -c \
        | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1\t/' || true)

    # _anchor_owner_count <token> -> distinct-skill count from $owner_counts
    # (a parent local, per this file's existing nested-function convention —
    # see _accumulate() inside compute_listing_cost() below). -F'\t' is load-
    # bearing: it makes $2 the whole rest-of-line (including any spaces in a
    # multi-word token) instead of just its first word.
    _anchor_owner_count() {
        printf '%s\n' "$owner_counts" | awk -F'\t' -v t="$1" '$2==t{print $1; f=1} END{if(!f) print 0}'
    }

    local json_lines=""
    for i in "${!skill_names[@]}"; do
        name="${skill_names[$i]}"
        local tok oc unique_tokens shared_tokens clause clause_tokens stated free
        unique_tokens=""; shared_tokens=""
        while IFS= read -r tok; do
            [ -z "$tok" ] && continue
            oc=$(_anchor_owner_count "$tok")
            if [ "$oc" -eq 1 ]; then
                unique_tokens="${unique_tokens}${tok}"$'\n'
            else
                shared_tokens="${shared_tokens}${tok}"$'\n'
            fi
        done <<< "${skill_tokens[$i]}"
        unique_tokens=$(printf '%s' "$unique_tokens" | grep -v '^$' || true)
        shared_tokens=$(printf '%s' "$shared_tokens" | grep -v '^$' || true)

        if [ "$ANCHORS_ONLY" = 1 ]; then
            # Build each skill's JSON fragment with jq itself (jq -R -s split on
            # "\n", never a shell join/re-split on ","): a token can legitimately
            # contain an internal comma (a backticked literal like `mvn clean
            # install, then deploy`), and `paste -sd, -` + jq's `split(",")` used
            # to corrupt exactly that token into two. A token cannot contain a
            # literal newline (it was extracted from a single-line variable), so
            # "\n" is the one delimiter guaranteed safe here. `-c` keeps each
            # fragment on one line so the outer split("\n") below still works.
            if command -v jq >/dev/null 2>&1; then
                json_lines="${json_lines}$(printf '%s\n' "$unique_tokens" | jq -R -s -c --arg name "$name" '
                    split("\n") | map(select(length > 0)) | {key: $name, value: .}
                ' 2>/dev/null)"$'\n'
            fi
            continue
        fi

        # Trigger-ish sentences (shared by NO-UNIQUE-ANCHOR / ANCHOR-NOT-STATED /
        # ANCHOR-COLLISION below). Split the full text into sentences and union
        # the anchor tokens of every sentence that reads as trigger-ish, rather
        # than extracting a single clause from the first phrase match to the end
        # of ONE sentence: a real description often states its trigger in one
        # sentence ("Use it for …") and names the very anchor token in another
        # ("… prefer the CodeGraph MCP tools.") — restricting to one sentence
        # would still miss it.
        local sentences sent clause_tokens_multi
        sentences=$(printf '%s\n' "${skill_texts[$i]}" | grep -oE "$ANCHOR_SENTENCE_UNIT_RE" 2>/dev/null || true)
        clause=""; clause_tokens_multi=""
        while IFS= read -r sent; do
            [ -z "$sent" ] && continue
            if printf '%s' "$sent" | grep -qiE "$ANCHOR_TRIGGER_SENTENCE_RE" 2>/dev/null; then
                [ -z "$clause" ] && clause="$sent"
                clause_tokens_multi="${clause_tokens_multi}$(anchor_tokens_from "$sent")"$'\n'
            fi
        done <<< "$sentences"
        clause_tokens=$(printf '%s' "$clause_tokens_multi" | grep -v '^$' | sort -u || true)

        # NO-UNIQUE-ANCHOR fires whenever unique_tokens is empty — full stop.
        # A trigger sentence's presence/absence selects WHICH of the two
        # remediations (plan requirement) prints; it must never gate whether
        # the tag fires at all. Exempting "has a trigger sentence" from this
        # check makes the tag unreachable for exactly the case it exists to
        # catch: a skill can write a complete trigger clause out of entirely
        # generic/shared vocabulary and still own nothing unique.
        #   - owns >=1 anchor-grade token but every one is shared, OR states a
        #     trigger sentence that itself names no anchor-grade token at all:
        #     "structurally un-anchorable" — wording cannot fix this, accept
        #     the overlap or merge with the skill that owns the artifact.
        #   - owns zero anchor-grade tokens AND states no trigger sentence
        #     either: the skill hasn't tried — state the specific artifact or
        #     term it uniquely handles, not just a generic verb.
        if [ -z "$unique_tokens" ]; then
            if [ -n "${skill_tokens[$i]}" ]; then
                error "[NO-UNIQUE-ANCHOR] $name: every anchor-grade token here ($(printf '%s' "$shared_tokens" | tr '\n' ',' | sed 's/,$//')) is also claimed by another skill — structurally un-anchorable: wording cannot create uniqueness, accept the overlap or merge with the skill that owns the artifact"
            elif [ -n "$clause" ]; then
                error "[NO-UNIQUE-ANCHOR] $name: states a trigger sentence, but it names no file extension, filename, backticked literal, hyphenated identifier, or mid-sentence proper noun either — structurally un-anchorable: a more elaborate trigger sentence cannot create uniqueness here, accept the overlap or merge with the skill that owns the artifact"
            else
                error "[NO-UNIQUE-ANCHOR] $name: description/when_to_use names no file extension, filename, backticked literal, hyphenated identifier, or mid-sentence proper noun, and states no trigger sentence either — state the specific artifact or term this skill uniquely handles, not just a generic verb"
            fi
        fi

        # ANCHOR-NOT-STATED (Hygiene): owns a unique token, never names it in
        # a trigger sentence — the study's exact one-sentence intervention.
        if [ -n "$unique_tokens" ]; then
            stated=$(comm -12 <(printf '%s\n' "$unique_tokens" | sort -u) <(printf '%s\n' "$clause_tokens" | sort -u) 2>/dev/null || true)
            if [ -z "$stated" ]; then
                warning "[ANCHOR-NOT-STATED] $name: owns unique anchor token(s) ($(printf '%s' "$unique_tokens" | tr '\n' ',' | sed 's/,$//')) but no trigger sentence ('Use for' / 'Use when' / 'Triggers on' / 'Always invoke for') names one"
            fi
        fi

        # ANCHOR-COLLISION (Structural): the trigger sentence exists but every
        # anchor-grade token in it is also claimed by another skill.
        if [ -n "$clause_tokens" ]; then
            free=$(comm -12 <(printf '%s\n' "$clause_tokens" | sort -u) <(printf '%s\n' "$unique_tokens" | sort -u) 2>/dev/null || true)
            if [ -z "$free" ]; then
                error "[ANCHOR-COLLISION] $name: trigger sentence names only token(s) ($(printf '%s' "$clause_tokens" | tr '\n' ',' | sed 's/,$//')) that other skills also claim — restate it around a token this skill uniquely owns"
            fi
        fi
    done

    if [ "$ANCHORS_ONLY" = 1 ]; then
        if command -v jq >/dev/null 2>&1; then
            printf '%s' "$json_lines" | jq -R -s '
                split("\n")
                | map(select(length > 0))
                | map(fromjson)
                | from_entries
            '
        else
            printf '{}\n'
        fi
    fi
}

# Sum description + when_to_use chars across every SKILL.md and command .md
# under CLAUDE_DIR. Mirrors what Claude Code feeds into the skill-listing block.
compute_listing_cost() {
    local total=0 count=0 desc when_to_use entry_chars
    _accumulate() {
        local f="$1"
        [ -f "$f" ] || return 0
        # A disable-model-invocation skill is removed from Claude's context
        # entirely (skills doc: Configure skills), so it costs no listing chars.
        local dmi
        dmi=$(extract_field "$f" "disable-model-invocation" | tr '[:upper:]' '[:lower:]')
        case "$dmi" in true|yes|on|1) return 0 ;; esac
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
        msdc=$(jq -r 'if type == "object" then .maxSkillDescriptionChars else null end | scalars // empty' "$CLAUDE_DIR/settings.json" 2>/dev/null || true)
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
            v=$(jq -r 'if type == "object" then .skillListingBudgetFraction else null end | scalars // empty' "$SETTINGS_JSON" 2>/dev/null || true)
            [ -n "$v" ] && FRACTION="$v"
        fi
        EFFECTIVE_BUDGET=$(awk -v f="$FRACTION" -v c="$CONTEXT_TOKENS" -v floor="$LISTING_BUDGET_FLOOR" \
            'BEGIN{ b = c * 4 * f; if (b < floor) b = floor; printf "%d", b }')
    fi
    OVER=$(( LIST_TOTAL - EFFECTIVE_BUDGET ))
    printf '%d %d %d %d\n' "$LIST_TOTAL" "$LIST_COUNT" "$EFFECTIVE_BUDGET" "$OVER"
    exit 0
fi

# --anchors: print {"skill":["token",...], ...} — unique anchor-grade tokens
# only — and exit. Same extraction as the interactive Anchor Analysis check;
# check_anchor_analysis() branches on ANCHORS_ONLY so the corpus walk runs once.
if [ "$ANCHORS_ONLY" = 1 ]; then
    check_anchor_analysis
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
    check_over_constrained "$CLAUDE_MD" "CLAUDE.md"
    check_claudemd_obvious "$CLAUDE_MD" "CLAUDE.md"
    check_claudemd_memory_drift "$CLAUDE_MD" "CLAUDE.md"
else
    warning "No CLAUDE.md found"
fi
# CLAUDE.local.md — personal, gitignored overrides; dead-ref + import checks too.
for cl in "$CLAUDE_DIR/CLAUDE.local.md" "$CLAUDE_DIR/../CLAUDE.local.md"; do
    [ -f "$cl" ] || continue
    check_dead_refs_in_file "$cl" "$(basename "$cl")"
    check_npm_scripts_in_file "$cl" "$(basename "$cl")"
    walk_imports "$cl" "$(basename "$cl")" 0
    check_over_constrained "$cl" "$(basename "$cl")"
    check_claudemd_obvious "$cl" "$(basename "$cl")"
    check_claudemd_memory_drift "$cl" "$(basename "$cl")"
done
# Guides CLAUDE.md routes to — ground their `npm run` mentions the same way.
if [ -d "$CLAUDE_DIR/documentation/guides" ]; then
    while IFS= read -r g; do
        check_npm_scripts_in_file "$g" "${g#"$CLAUDE_DIR"/}"
    done < <(find "$CLAUDE_DIR/documentation/guides" -name '*.md' 2>/dev/null | sort)
fi
check_local_md_tracked
check_claudeignore
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
check_plugin_skill_risk
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

    # Check: non-descriptive reference filename (doc2.md, file1.md).
    if printf '%s' "$(basename "$ref_file")" | grep -Eiq "$VAGUE_REF_NAME_RE"; then
        warning "[VAGUE-NAME] $ref_name: reference filename is non-descriptive — name it for its content (form_validation_rules.md, not doc2.md)"
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
    check_time_and_paths        "$ref_file" "$ref_name"
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
        check_inert_permission_rules  "$settings_file" "$sdisp"
        check_hook_timeouts          "$settings_file" "$sdisp"
        check_hook_matchers          "$settings_file" "$sdisp"
        check_http_hook_env          "$settings_file" "$sdisp"
        check_http_hook_allowlist    "$settings_file" "$sdisp"
        check_settings_security      "$settings_file" "$sdisp"
        check_settings_scope_ignored   "$settings_file" "$sdisp"
        check_settings_deprecated_keys "$settings_file" "$sdisp"
        check_claudemd_excludes        "$settings_file" "$sdisp"
        check_worktree_sparse          "$settings_file" "$sdisp"
    fi
done
check_global_config_removed
# hooks/hooks.json holds hook definitions but no allowlist of its own, so it is
# checked against the allowlist merged from the settings files above.
check_http_hook_allowlist "$CLAUDE_DIR/hooks/hooks.json" "hooks/hooks.json"
check_hook_timeouts "$CLAUDE_DIR/hooks/hooks.json" "hooks/hooks.json"
check_hook_matchers "$CLAUDE_DIR/hooks/hooks.json" "hooks/hooks.json"
check_mcp_preapproved_live
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
check_rule_path_lost_on_compact
echo ""

# --- Check 9: Name collisions (commands vs skills) ---
bold "--- Name Collisions ---"
check_name_collisions
echo ""

# --- Check 10: Context coherence (repetition across context sources) ---
bold "--- Context Coherence ---"
check_instruction_duplication
echo ""

# --- Check 11: Anchor analysis (unique-trigger-token ownership) ---
bold "--- Anchor Analysis ---"
check_anchor_analysis
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
