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
| `CONTEXT-BLOAT` | `output > 500000` cumulative in one session, OR (`turns >= 5 AND output/turns > 1800`) | Structural |

Defaults `CACHE_HIT_FLOOR=0.30`, `CONTEXT_BLOAT_OUTPUT=500000`, `CONTEXT_BLOAT_PER_TURN=1800` — each overridable per install via the env var of the same name.

## Calibration

The previous defaults (`200000` / `8000`) were fitted to record-summed totals; the `message.id`
dedupe deflates the fleet by **4.0× on `output`** and **2.08× on `turns`**, so they no longer mean
what they meant. Re-measured on one 30-day install (196 sessions, 1016 transcripts):

| Metric (deduped) | p50 | p75 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| `output` per session | 11424 | 92417 | 197843 | 320678 | 653585 | 996139 |
| `output/turns`, sessions with `turns >= 5` | 519 | 1051 | 1293 | 1462 | 1739 | 1904 |

- **`CONTEXT_BLOAT_OUTPUT=500000`** — flags 4/196 (the marathon tail); `200000` flagged 20/196, a
  quartile rather than a tail. It is deliberately **half** the goal-loop plugin's hard run budget
  (`budget.maxOutputTokens = 1000000`), so the two layer: this audit WARNS at the halfway mark,
  goal-loop ESCALATES at the cap.
- **`CONTEXT_BLOAT_PER_TURN=1800`, gated on `turns >= 5`** — ≈ p99 of the multi-turn population and
  ≈ 3.5× its median; flags 1/196, so the tag as a whole flags 5/196. `8000` fired on **zero**
  sessions even pre-dedupe (raw `output/turns` peaks at 3400), so it was dead rather than
  mis-scaled, and a proportional rescale to ~4000 would keep it dead. The `turns >= 5` guard is
  required: without it the entire top of the per-turn ranking is single-turn sessions, where
  `output/turns == output` — one long answer, not context bloat.
- **`CACHE_HIT_FLOOR=0.30` — unchanged.** The dedupe is ratio-neutral: `cache_read` and its
  denominator come from the same `message.usage` object, and per-session raw vs deduped ratios
  differ by at most 0.05 on the measured install. The observed floor there is 0.776, so `0.30`
  keeps its intent — a "something is badly wrong" threshold a healthy install never touches, not
  a percentile cut.

These counts are one machine's; re-derive them before trusting them elsewhere
(`scan-history.sh --no-cache` with a scratch `CLAUDE_PLUGIN_DATA`, then percentile `.tokenUsage`).

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
