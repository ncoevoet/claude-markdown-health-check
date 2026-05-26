# Token Trend (Context Bloat) — Phase 23

Per-session token usage mined from `message.usage` events in JSONL. Runs at Deep depth only.

## Source

`history-scan.json` → `.tokenUsage[<sessionId>]` = `{input, output, cache_read, cache_creation, turns}`.

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
