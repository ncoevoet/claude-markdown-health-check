# Token Trend (Context Bloat) — Phase 23

Per-session token usage mined from `message.usage` events in JSONL. Runs at Deep depth only.

## Source

`history-scan.json` → `.tokenUsage[<sessionId>]` = `{input, output, cache_read, cache_creation, turns}`.

Counts are **deduplicated by `message.id`**. Claude Code writes one JSONL record per
assistant content block (text / thinking / tool_use), and every record of a message
repeats the *same* `message.usage` object — so summing records inflates both `turns` and
the token totals 3–4×. `scan-history.sh` keeps the first usage event per
`(sessionId, message.id)`: `turns` is the **distinct message count**, and each message's
tokens are added once. Records carrying no `message.id` cannot be deduped and each stay
their own turn.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `LOW-CACHE-HIT` | `turns >= 5 AND cache_read / (input + cache_read + cache_creation) < 0.30` | Hygiene |
| `CONTEXT-BLOAT` | `output > 200000` cumulative in one session, OR `output/turns > 8000` average | Structural |

Thresholds `CACHE_HIT_FLOOR=0.30` and `CONTEXT_BLOAT_OUTPUT=200000`, `CONTEXT_BLOAT_PER_TURN=8000` are guesses — tune per install via env override (`CACHE_HIT_FLOOR`, `CONTEXT_BLOAT_OUTPUT`, `CONTEXT_BLOAT_PER_TURN`).

## Report block

```
### Context Trend (last 30d)
Sessions: N · Low cache: X · Bloated: Y
Worst cache hit: <ratio>% in <sessionId-prefix>
```

## Remediation order

1. `CONTEXT-BLOAT` → review the session post-mortem; likely candidates are skills with oversized bodies or hooks that inject context per turn.
2. `LOW-CACHE-HIT` → the session has high prompt churn — early system-prompt edits or frequent re-runs of `/clear` may be the cause.

## Privacy

Session IDs are kept (UUIDs, no PII) but `cwd` paths are stripped by `scan-history.sh`. Findings reference the session-ID prefix only.
