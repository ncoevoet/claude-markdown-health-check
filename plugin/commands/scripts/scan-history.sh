#!/usr/bin/env bash
# scan-history.sh — Mine local Claude Code history for skill usage, hook
# reliability, tool denials, user corrections, agent spawns, and per-session
# token usage. Emits an AGGREGATE JSON — phases 7/9/15/16/19/22/23 read it
# and apply their own heuristics + tag emission.
#
# Usage: scan-history.sh [--window-days N] [--no-cache] [--refresh] [--quick-scan] [--anchors-file <path>]
#
# Sources:
#   ~/.claude/projects/*/<uuid>.jsonl       (transcripts)
#   ~/.claude.json#skillUsage               (native usage ledger)
#   ~/.claude/telemetry/1p_failed_events.*.json
#   ~/.claude/usage-data/{session-meta,facets}/*.json
#
# Output: ${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/history-scan.json
# TTL: 24h (override via SCAN_HISTORY_TTL).
# Hard cap: 60s wall time. On timeout, meta.partial=true.

set -uo pipefail

WINDOW_DAYS=30
NO_CACHE=0
REFRESH=0
ANCHORS_FILE=""
TIME_BUDGET=${SCAN_HISTORY_BUDGET:-60}
while [ $# -gt 0 ]; do
    case "$1" in
        --window-days) WINDOW_DAYS="$2"; shift 2 ;;
        --window-days=*) WINDOW_DAYS="${1#*=}"; shift ;;
        --no-cache) NO_CACHE=1; shift ;;
        --refresh)  REFRESH=1; shift ;;
        --quick-scan) TIME_BUDGET=30; shift ;;
        # `${2:-}` + a shift count clamped to $# keeps a trailing, value-less
        # --anchors-file a graceful no-op (empty ANCHORS_FILE -> ANCHORS_JSON
        # stays "{}") instead of an unbound-variable abort under `set -u`,
        # matching every other error path in this script (see :46).
        --anchors-file) ANCHORS_FILE="${2:-}"; shift "$([ $# -ge 2 ] && echo 2 || echo 1)" ;;
        --anchors-file=*) ANCHORS_FILE="${1#*=}"; shift ;;
        *) shift ;;
    esac
done

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}"
CACHE_FILE="$CACHE_DIR/history-scan.json"
mkdir -p "$CACHE_DIR"

TTL_SECONDS=${SCAN_HISTORY_TTL:-86400}
MAX_LINE_BYTES=5242880

command -v jq >/dev/null 2>&1 || { echo '{"meta":{"partial":true,"reason":"jq missing"}}'; exit 0; }

# Fingerprint of the anchors input (content hash, not just presence), so that
# adding/removing/changing --anchors-file between runs is a cache miss even
# when its mtime+size happen to collide. "none" when no --anchors-file was
# passed, so a plain run vs. an anchors-file run are also distinguished.
anchors_fingerprint() {
    if [ -n "$ANCHORS_FILE" ] && [ -f "$ANCHORS_FILE" ]; then
        md5sum "$ANCHORS_FILE" 2>/dev/null | awk '{print $1}'
    else
        echo "none"
    fi
}

if [ "$NO_CACHE" = 0 ] && [ "$REFRESH" = 0 ] && [ -s "$CACHE_FILE" ]; then
    cache_window=$(jq -r '.meta.window_days // empty' "$CACHE_FILE" 2>/dev/null)
    cache_anchors_fp=$(jq -r '.meta.anchors_fingerprint // empty' "$CACHE_FILE" 2>/dev/null)
    if [ "$cache_window" = "$WINDOW_DAYS" ] && [ "$cache_anchors_fp" = "$(anchors_fingerprint)" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$TTL_SECONDS" ]; then
            cat "$CACHE_FILE"
            exit 0
        fi
    fi
fi

START_TS=$(date +%s)
T_CUTOFF=$(date -d "$WINDOW_DAYS days ago" +%s)
T_CUTOFF_ISO=$(date -d "@$T_CUTOFF" -u +"%Y-%m-%dT%H:%M:%SZ")
GEN_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

PROJECTS_DIR="$HOME/.claude/projects"
TELEMETRY_DIR="$HOME/.claude/telemetry"
SKILLUSAGE_FILE="$HOME/.claude.json"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"

PARTIAL=0
PARTIAL_REASON=""
log() { printf '[scan-history] %s\n' "$1" >&2; }

elapsed() { echo $(( $(date +%s) - START_TS )); }
over_budget() { [ "$(elapsed)" -ge "$TIME_BUDGET" ]; }

# shellcheck disable=SC2089  # this is a jq program (a string literal), not shell
PER_FILE_FILTER='
def epoch_of:
    # Real Claude Code transcripts carry millisecond precision
    # ("...SS.mmmZ"), which the builtin fromdateiso8601 cannot parse at all
    # (it only understands whole-second "...SSZ") -- it throws, and the old
    # `try/catch null` here silently turned EVERY real event epoch into
    # null. Strip an optional ".ddd" fractional-second group, but only when
    # it sits immediately before a trailing "Z" or numeric UTC offset, then
    # hand off to fromdateiso8601 same as before. A non-"Z" offset (rare --
    # Claude Code always emits "Z") is still not understood by
    # fromdateiso8601 and fails soft to null, same as any other unparseable
    # shape; this keeps the existing fail-soft contract, it just no longer
    # fails soft on the one shape that matters in production.
    # Explicit `if type != "string" then null` (rather than `// empty`)
    # matters too: `.timestamp // empty` on a missing/null timestamp used to
    # produce an EMPTY jq stream, not a null value, which made the caller
    # `(epoch_of) as $ts | ...` binding emit zero results -- i.e. silently
    # drop the whole event instead of falling through the null branch below.
    (.timestamp) as $raw
    | if ($raw | type) != "string" then null
      else
        ($raw | sub("\\.[0-9]+(?=(Z|[+-][0-9]{2}:?[0-9]{2})$)"; "")) as $stripped
        | (try ($stripped | fromdateiso8601) catch null)
      end;
def rejected_text:
    (.content // "") | tostring | ascii_downcase
    | test("user (doesn'\''t|did not|did not want) (to|).*(proceed|continue)|tool use was rejected|user rejected|permission denied");
# Anchor tokens are literal text, not regexes, and some contain regex
# metacharacters ("." in ".logx"/"pom.xml", "-" in "my-file.txt"). Escape
# every Oniguruma metacharacter so the token is matched as itself.
def esc_re:
    gsub("(?<c>[.\\\\^$|?*+()\\[\\]{}-])"; "\\\(.c)");
def is_wordchar: test("^[a-z0-9_]$");
# Build a boundary-aware regex for one already-lowercased anchor token.
# A plain `\b` does not do this: `\b` is only true at a transition between a
# word char and a non-word char (or a string edge next to a word char), so
# `\b` placed right before a token that STARTS with a non-word char (the
# "." of ".logx") is false at the very start of a string -- it would never
# match ".logx files" at position 0. And a `\b` written in the middle of a
# token containing "-" or a space ("my-file.txt", "mvn clean install")
# anchors to that internal gap, not to the outer edges of the token, which is not
# what we want either. So: escape the token, then only require a boundary
# on a side whose OWN edge character is itself a word char. A token edge
# that is already punctuation ("." leading ".logx", "-"/" " leading or
# trailing inside a multi-word token) cannot be silently absorbed into a
# larger identifier, so no assertion is needed on that side.
def anchor_pattern:
    . as $tok
    | ($tok | esc_re) as $escaped
    | (if ($tok[0:1] | is_wordchar) then "(?<![a-z0-9_])" else "" end) as $left
    | (if ($tok[-1:] | is_wordchar) then "(?![a-z0-9_])" else "" end) as $right
    | $left + $escaped + $right;
# validate-skills.sh --anchors emits its full five-class set UNFILTERED
# (extension, dotted filename, backtick literal, hyphenated identifier,
# mid-sentence proper noun) -- that set is required verbatim by
# NO-UNIQUE-ANCHOR/ANCHOR-COLLISION and by the shared Jaccard base that
# SKILL-DUPLICATE-DOMAIN uses (skill-listing-budget.md), so it must not be thinned at the
# source. But a bare proper noun ("claude"), acronym ("ci"), or hyphenated
# identifier ("threat-model") carries no discriminative power in a prompt
# corpus -- users type ordinary words in conversation without wanting the
# skill that happens to own one (measured: "claude" alone appears in over
# half of all prompts in a real 30d/~2300-prompt window, which made
# SKILL-LOW-OBSERVED-RECALL fire on nearly every skill). This join is
# therefore restricted to the three token classes a user would only type
# when actually naming a concrete artifact: a leading-dot extension
# (".logx"), a dotted filename ("pom.xml"), or a MULTI-WORD backticked
# literal ("ng build") -- recognizable because a multi-word token is the
# only class that can contain a space; every other class is one identifier.
# Filtering happens HERE (the consumer), not upstream in the Phase 5/7
# wiring that builds --anchors-file: tests/test_history.sh drives this
# script directly with a synthetic anchors file, bypassing that wiring
# entirely, so a filter placed there would be untested and silently
# skippable by any other caller. See skill-usage-metrics.md for the
# rubric-level statement of this rule.
def is_artifact_shaped:
    test(" ")
    or test("^\\.[a-z0-9]{2,6}$")
    or test("^[a-z0-9_-]+\\.[a-z0-9]{2,6}$");
select(. != null) | (epoch_of) as $ts
| if $ts == null or $ts >= $cutoff then
    if (.message.content? | type == "array") then
      .message.content[] as $c
      | if ($c.type? == "tool_use") and ($c.name? == "Skill") then
          {kind:"skill", session:.sessionId, ts:$ts, skill:($c.input.skill // null), args:($c.input.args // null)}
        elif ($c.type? == "tool_use") and ($c.name? == "Agent") then
          {kind:"agent", session:.sessionId, ts:$ts, subagent:($c.input.subagent_type // null)}
        elif ($c.type? == "tool_use") then
          {kind:"tool_call", session:.sessionId, ts:$ts, name:$c.name}
        elif ($c.type? == "tool_result") and (($c.is_error // false) == true) and ($c | rejected_text) then
          {kind:"denial", session:.sessionId, ts:$ts}
        else empty end
    else empty end,
    if (.attachment.type? == "hook_success") then
      {kind:"hook", session:.sessionId, ts:$ts, hook:.attachment.hookName, event:.attachment.hookEvent, exit:(.attachment.exitCode // 0)}
    elif (.attachment.type? == "hook_non_blocking_error") then
      {kind:"hook", session:.sessionId, ts:$ts, hook:(.attachment.hookName // "unknown"), event:(.attachment.hookEvent // "unknown"), exit:1}
    else empty end,
    if (.message.usage?) then
      {kind:"usage", session:.sessionId, mid:(.message.id // null), ts:$ts,
       in:(.message.usage.input_tokens // 0),
       out:(.message.usage.output_tokens // 0),
       cr:(.message.usage.cache_read_input_tokens // 0),
       cc:(.message.usage.cache_creation_input_tokens // 0)}
    else empty end,
    if (.type? == "user" and (.message.content? | type == "string")
        and ((.isMeta // false) | not) and ((.isSidechain // false) | not)) then
      (.message.content | ascii_downcase) as $txt
      | (if ($txt | test("^(no|nope|not that|wait|stop|always|never)\\b"))
            and (($txt | test("^stop hook feedback")) | not) then
           {kind:"correction", session:.sessionId, ts:$ts, text:($txt[0:120])}
         else empty end),
        # anchor_hit: $txt matches an ARTIFACT-SHAPED anchor token (per
        # is_artifact_shaped above -- a bare proper noun/acronym/hyphenated
        # identifier is excluded before this ever runs) owned by a skill
        # (per --anchors-file) at a WORD BOUNDARY, via anchor_pattern
        # (defined above) -- not a bare substring test. ".logx" matches
        # "call.logx" but not "the logx format"; "pom.xml" and
        # "mvn clean install" match only as whole tokens, not as a fragment
        # of a longer word. Skill name + ts + session ONLY -- never the
        # prompt text, stricter than "correction" above on purpose (privacy
        # stance, skill-usage-metrics.md:55-57).
        # Remaining limits: (1) a multi-word token matches only that exact
        # run of single spaces -- reflow, double spaces, or reordering does
        # not match; (2) [a-z0-9_] is the only "word" alphabet considered, so a
        # token bordered by other non-ASCII word characters could still
        # over/under-match. Neither changes the count-not-verdict contract:
        # a hit still is not proof the skill SHOULD have fired (the user may
        # just be discussing the token), so downstream wording must stay a
        # count, never a verdict.
        ( ($anchors // {} | to_entries[]) as $anchor_entry
          | (($anchor_entry.value // []) | map(ascii_downcase) | map(select(. != "")) | map(select(is_artifact_shaped))) as $tokens
          | select($tokens | any(. as $tok | $txt | test($tok | anchor_pattern)))
          | {kind:"anchor_hit", session:.sessionId, ts:$ts, skill:$anchor_entry.key}
        )
    else empty end
  else empty end
'

# The caller passes the FULL output path, never a directory: two transcripts can
# share a basename under different project dirs (a resumed/forked session, a
# copied tree), and deriving the name from `basename "$f"` would make them
# collide — silently dropping one file's events, or interleaving both, since
# these run backgrounded. The name is assigned by the parent loop before the
# fork, so it is unique by construction and race-free.
process_jsonl() {
    local f="$1" out_file="$2"
    awk -v max="$MAX_LINE_BYTES" 'length($0) < max' "$f" 2>/dev/null \
        | jq -c --argjson cutoff "$T_CUTOFF" --argjson anchors "$ANCHORS_JSON" "$PER_FILE_FILTER" 2>/dev/null \
        > "$out_file" || true
}

# Slurped once here (not re-read per file): --anchors-file takes a path, per
# the --slurpfile precedent below (:332-334 era), rather than putting raw
# anchor JSON on argv. Falls open to "{}" on a missing/unreadable/invalid
# file, same fail-open style as the rest of this script.
ANCHORS_JSON='{}'
if [ -n "$ANCHORS_FILE" ] && [ -f "$ANCHORS_FILE" ]; then
    parsed_anchors=$(jq -c '.' "$ANCHORS_FILE" 2>/dev/null) && [ -n "$parsed_anchors" ] && ANCHORS_JSON="$parsed_anchors"
fi

export -f process_jsonl
# shellcheck disable=SC2090  # PER_FILE_FILTER is a jq program string, exported intentionally
export PER_FILE_FILTER T_CUTOFF MAX_LINE_BYTES ANCHORS_JSON

collect_jsonl_events() {
    [ -d "$PROJECTS_DIR" ] || return 0
    local files_list="$TMP_DIR/files.list"
    find "$PROJECTS_DIR" -name '*.jsonl' -type f -newermt "$WINDOW_DAYS days ago" 2>/dev/null >"$files_list"
    local total
    total=$(wc -l <"$files_list" | tr -d ' ')
    [ "$total" = 0 ] && { log "no jsonl files in window"; return 0; }
    log "scanning $total jsonl files (window=${WINDOW_DAYS}d)"

    local parallel; parallel=$(nproc 2>/dev/null || echo 4)
    local count=0
    while IFS= read -r f; do
        if over_budget; then
            PARTIAL=1; PARTIAL_REASON="time_budget_${TIME_BUDGET}s"
            log "BUDGET EXCEEDED at $count/$total"
            return 0
        fi
        count=$((count + 1))
        process_jsonl "$f" "$EXTRACT_DIR/$count.events" &
        if (( count % parallel == 0 )); then
            wait
        fi
        if (( count % 100 == 0 )); then
            log "phase=jsonl files=$count/$total elapsed=$(elapsed)s"
        fi
    done <"$files_list"
    wait
}

# Claude Code writes ONE JSONL record per assistant content block (text /
# thinking / tool_use), and every record of a message repeats the SAME
# message.usage object. Summing every record therefore inflates turns and token
# totals 3-4x, so keep only the FIRST usage event per (session, message.id).
# One streaming pass, no sort: the seen-set holds one key per message, not per
# record. Records with no message.id cannot be deduped and each stay their own
# turn. Coupled to the compact key order jq -c emits for the usage event above;
# anything that does not parse falls through and is kept (fail-open).
DEDUP_USAGE_AWK='
index($0, "{\"kind\":\"usage\",") != 1 { print; next }
{
    sid = ""; mid = "";
    if (match($0, /"session":"[^"]*"/)) sid = substr($0, RSTART + 11, RLENGTH - 12);
    if (match($0, /"mid":"[^"]*"/))     mid = substr($0, RSTART + 7,  RLENGTH - 8);
    if (mid == "") { print; next }
    key = sid "\034" mid;
    if (key in seen) next;
    seen[key] = 1;
    print;
}
'

aggregate_jsonl() {
    local merged="$TMP_DIR/events.jsonl"
    : >"$merged"
    cat "$EXTRACT_DIR"/*.events 2>/dev/null | awk "$DEDUP_USAGE_AWK" >>"$merged" || true

    jq -s '
        def session_set: map(.session // "_") | unique;
        def by_skill:
            map(select(.kind == "skill" and .skill))
            | group_by(.skill)
            | map({
                key:.[0].skill,
                value:{
                    invokes: length,
                    sessions: (session_set | length),
                    last_ts: (max_by(.ts) | .ts)
                }
            }) | from_entries;
        # Observed trigger recall: join anchor_hit events (a prompt contained a
        # token a skill uniquely owns, per --anchors-file) against the SAME
        # "skill fired" criterion by_skill uses (kind=="skill" and .skill) --
        # deliberately not a second, differently-derived fired-events stream.
        # A hit "triggers" if some fire for the same (session, skill) lands
        # within 300s AFTER it, else it "misses". There is no turn index in
        # this event stream, so 300s is a heuristic proxy, not a real adjacency
        # check -- same caveat as the SKILL-MISFIRING sessions/invokes proxy.
        # A miss is evidence, not a verdict: the prompt may have discussed the
        # token without asking for the skill to act.
        def by_observed_recall:
            . as $all_events
            | ($all_events | map(select(.kind == "skill" and .skill))) as $fires
            | ($all_events | map(select(.kind == "anchor_hit" and .skill)))
            | group_by(.skill)
            | map({
                key: .[0].skill,
                value: (
                    map(
                        . as $hit
                        | ($fires | any(
                            .session == $hit.session and .skill == $hit.skill
                            and .ts != null and $hit.ts != null
                            and .ts >= $hit.ts and .ts <= ($hit.ts + 300)
                          ))
                    ) as $matched
                    | {
                        triggers: ($matched | map(select(.)) | length),
                        misses: ($matched | map(select(. | not)) | length)
                      }
                )
            }) | from_entries;
        def by_agent:
            map(select(.kind == "agent" and .subagent))
            | group_by(.subagent)
            | map({
                key:.[0].subagent,
                value:{
                    count: length,
                    sessions: (session_set | length)
                }
            }) | from_entries;
        def by_hook:
            map(select(.kind == "hook" and .hook))
            | group_by(.hook)
            | map({
                key:.[0].hook,
                value:{
                    total: length,
                    failures: (map(select((.exit // 0) != 0)) | length),
                    events: (map(.event // "") | unique)
                }
            }) | from_entries;
        def by_session_usage:
            map(select(.kind == "usage" and .session))
            | group_by(.session)
            | map({
                key:.[0].session,
                value:{
                    input: ([.[].in] | add),
                    output: ([.[].out] | add),
                    cache_read: ([.[].cr] | add),
                    cache_creation: ([.[].cc] | add),
                    turns: length
                }
            }) | from_entries;
        def corrections_list:
            map(select(.kind == "correction"))
            | map({session:.session, text:(.text // "")})
            | [.[0:200] | .[]];
        def skill_tool_pairs:
            map(select(.kind == "tool_call"))
            | group_by(.name)
            | map({key:.[0].name, value:length})
            | from_entries;
        def denial_count:
            map(select(.kind == "denial")) | length;
        {
            skills: by_skill,
            observedRecall: by_observed_recall,
            agentSpawns: by_agent,
            hookEvents: by_hook,
            tokenUsage: by_session_usage,
            corrections: corrections_list,
            toolCalls: skill_tool_pairs,
            denialCount: denial_count
        }
    ' "$merged" 2>/dev/null || echo '{}'
}

collect_telemetry() {
    [ -d "$TELEMETRY_DIR" ] || { echo '{}'; return 0; }
    local files_list="$TMP_DIR/tel.list"
    find "$TELEMETRY_DIR" -name '*.json' -type f -newermt "$WINDOW_DAYS days ago" 2>/dev/null >"$files_list"
    local total
    total=$(wc -l <"$files_list" | tr -d ' ')
    [ "$total" = 0 ] && { echo '{}'; return 0; }
    log "scanning $total telemetry files"

    # shellcheck disable=SC2046  # intentional word-split: session jsonl paths have no spaces
    jq -s '
        [ .[] | .[]? | select(.event_data? != null) | .event_data.event_name ]
        | group_by(.) | map({key:.[0], value:length}) | from_entries
        | {eventCounts:.}
    ' $(cat "$files_list") 2>/dev/null || echo '{}'
}

collect_skill_usage_ledger() {
    [ -f "$SKILLUSAGE_FILE" ] || { echo '{}'; return 0; }
    # Raw per-machine cumulative ledger, plus a normalization pass: a skill invoked
    # as a subagent is recorded under "agents:<name>" (e.g. "agents:code-review-agent"),
    # which Phase 7's exact-name lookup would otherwise miss and mis-flag as never-fired.
    # Fold each "agents:<name>" entry into a bare "<name>" alias (summing usageCount,
    # keeping the latest lastUsedAt) while preserving the original keys.
    jq -c '
      (.skillUsage // {}) as $raw
      | reduce ($raw | to_entries[]) as $e ($raw;
          if ($e.key | startswith("agents:")) then
            ($e.key | ltrimstr("agents:")) as $base
            | .[$base] = ((.[$base] // {usageCount:0, lastUsedAt:0})
                | .usageCount += ($e.value.usageCount // 0)
                | .lastUsedAt = ([.lastUsedAt, ($e.value.lastUsedAt // 0)] | max))
          else . end)
    ' "$SKILLUSAGE_FILE" 2>/dev/null || echo '{}'
}

main() {
    log "window=${WINDOW_DAYS}d cutoff=$T_CUTOFF_ISO budget=${TIME_BUDGET}s"
    collect_jsonl_events
    if over_budget; then
        PARTIAL=1
        [ -z "$PARTIAL_REASON" ] && PARTIAL_REASON="time_budget_jsonl"
    fi

    local jsonl_agg telemetry_agg ledger
    jsonl_agg=$(aggregate_jsonl)
    telemetry_agg=$(collect_telemetry)
    ledger=$(collect_skill_usage_ledger)

    local total_files
    total_files=$(find "$EXTRACT_DIR" -name '*.events' 2>/dev/null | wc -l | tr -d ' ')

    local meta
    meta=$(jq -c -n \
        --arg gen "$GEN_AT" \
        --arg cutoff "$T_CUTOFF_ISO" \
        --argjson days "$WINDOW_DAYS" \
        --argjson files "$total_files" \
        --argjson elapsed "$(elapsed)" \
        --argjson partial "$PARTIAL" \
        --arg reason "$PARTIAL_REASON" \
        --arg anchors_fp "$(anchors_fingerprint)" \
        '{generated_at:$gen, window_days:$days, cutoff_iso:$cutoff,
          files_scanned:$files, elapsed_seconds:$elapsed,
          partial:($partial==1), partial_reason:$reason,
          anchors_fingerprint:$anchors_fp}')

    # Route the large aggregates through files (--slurpfile), not argv (--argjson):
    # on installs with thousands of transcripts these blobs exceed ARG_MAX and jq
    # aborts with "Argument list too long", leaving an empty history-scan.json.
    local out_tmp="$CACHE_FILE.tmp"
    local jsonl_tmp="$CACHE_FILE.jsonl.tmp" tel_tmp="$CACHE_FILE.tel.tmp" ledger_tmp="$CACHE_FILE.ledger.tmp"
    printf '%s' "$jsonl_agg"     > "$jsonl_tmp"
    printf '%s' "$telemetry_agg" > "$tel_tmp"
    printf '%s' "$ledger"        > "$ledger_tmp"
    jq -n \
        --argjson meta "$meta" \
        --slurpfile jsonl "$jsonl_tmp" \
        --slurpfile tel "$tel_tmp" \
        --slurpfile ledger "$ledger_tmp" \
        '($jsonl[0] // {}) as $j | ($tel[0] // {}) as $t | ($ledger[0] // {}) as $l |
         {
            meta:$meta,
            skills:($j.skills // {}),
            observedRecall:($j.observedRecall // {}),
            skillLedger:$l,
            denials:{count:($j.denialCount // 0)},
            apiEvents:$t,
            hookEvents:($j.hookEvents // {}),
            agentSpawns:($j.agentSpawns // {}),
            corrections:($j.corrections // []),
            tokenUsage:($j.tokenUsage // {})
         }' > "$out_tmp"

    rm -f "$jsonl_tmp" "$tel_tmp" "$ledger_tmp"
    mv -f "$out_tmp" "$CACHE_FILE"
    cat "$CACHE_FILE"
}

main
