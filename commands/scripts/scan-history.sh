#!/usr/bin/env bash
# scan-history.sh — Mine local Claude Code history for skill usage, hook
# reliability, tool denials, user corrections, agent spawns, and per-session
# token usage. Emits an AGGREGATE JSON — phases 7/9/15/16/19/22/23 read it
# and apply their own heuristics + tag emission.
#
# Usage: scan-history.sh [--window-days N] [--no-cache] [--refresh] [--quick-scan]
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
TIME_BUDGET=${SCAN_HISTORY_BUDGET:-60}
while [ $# -gt 0 ]; do
    case "$1" in
        --window-days) WINDOW_DAYS="$2"; shift 2 ;;
        --window-days=*) WINDOW_DAYS="${1#*=}"; shift ;;
        --no-cache) NO_CACHE=1; shift ;;
        --refresh)  REFRESH=1; shift ;;
        --quick-scan) TIME_BUDGET=30; shift ;;
        *) shift ;;
    esac
done

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.cache}"
CACHE_FILE="$CACHE_DIR/history-scan.json"
mkdir -p "$CACHE_DIR"

TTL_SECONDS=${SCAN_HISTORY_TTL:-86400}
MAX_LINE_BYTES=5242880

command -v jq >/dev/null 2>&1 || { echo '{"meta":{"partial":true,"reason":"jq missing"}}'; exit 0; }

if [ "$NO_CACHE" = 0 ] && [ "$REFRESH" = 0 ] && [ -s "$CACHE_FILE" ]; then
    cache_window=$(jq -r '.meta.window_days // empty' "$CACHE_FILE" 2>/dev/null)
    if [ "$cache_window" = "$WINDOW_DAYS" ]; then
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
    (.timestamp // empty)
    | if type=="string" then
        (try (fromdateiso8601) catch null)
      else null end;
def rejected_text:
    (.content // "") | tostring | ascii_downcase
    | test("user (doesn'\''t|did not|did not want) (to|).*(proceed|continue)|tool use was rejected|user rejected|permission denied");
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
      {kind:"usage", session:.sessionId, ts:$ts,
       in:(.message.usage.input_tokens // 0),
       out:(.message.usage.output_tokens // 0),
       cr:(.message.usage.cache_read_input_tokens // 0),
       cc:(.message.usage.cache_creation_input_tokens // 0)}
    else empty end,
    if (.type? == "user" and (.message.content? | type == "string")) then
      (.message.content | ascii_downcase) as $txt
      | if ($txt | test("^(no|nope|not that|wait|stop|always|never)\\b")) then
          {kind:"correction", session:.sessionId, ts:$ts, text:($txt[0:120])}
        else empty end
    else empty end
  else empty end
'

process_jsonl() {
    local f="$1" out_base="$2"
    local fname
    fname=$(basename "$f")
    awk -v max="$MAX_LINE_BYTES" 'length($0) < max' "$f" 2>/dev/null \
        | jq -c --argjson cutoff "$T_CUTOFF" "$PER_FILE_FILTER" 2>/dev/null \
        > "$out_base/$fname.events" || true
}

export -f process_jsonl
# shellcheck disable=SC2090  # PER_FILE_FILTER is a jq program string, exported intentionally
export PER_FILE_FILTER T_CUTOFF MAX_LINE_BYTES

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
        process_jsonl "$f" "$EXTRACT_DIR" &
        count=$((count + 1))
        if (( count % parallel == 0 )); then
            wait
        fi
        if (( count % 100 == 0 )); then
            log "phase=jsonl files=$count/$total elapsed=$(elapsed)s"
        fi
    done <"$files_list"
    wait
}

aggregate_jsonl() {
    local merged="$TMP_DIR/events.jsonl"
    : >"$merged"
    cat "$EXTRACT_DIR"/*.events 2>/dev/null >>"$merged" || true

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
        '{generated_at:$gen, window_days:$days, cutoff_iso:$cutoff,
          files_scanned:$files, elapsed_seconds:$elapsed,
          partial:($partial==1), partial_reason:$reason}')

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
