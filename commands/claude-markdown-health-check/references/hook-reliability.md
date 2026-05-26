# Hook Latency + Reliability — Phase 16

Per-hook reliability mined from `attachment.type == "hook_success"` and `attachment.type == "hook_non_blocking_error"` events in JSONL. Runs at Standard + Deep depth.

## Source

`history-scan.json` → `.hookEvents[<hookName>]` = `{total, failures, events}`.

Telemetry-side latency data (`waiting_for_user_permission_ms`) is NOT captured by the local Claude Code telemetry stream observed on this install — the planned `HOOK-SLOW` heuristic is parked until that data path is reinstated.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `HOOK-FAILING` | `total>=10 AND failures/total > 0.25` | Structural; **Critical** at `failures/total == 1.0 AND total >= 5` |
| `HOOK-NEVER-FIRED` | hook registered in `settings.json` but `total == 0` in window | Hygiene |
| `HOOK-EVENT-MISMATCH` | hook's registered events differ from observed `events[]` set | Structural |
| `HOOK-SLOW` | parked (no latency data) | — |

`HOOK-FAILING` is owned by this phase (not phase 19) so it fires at Standard depth too.

## Report block

```
### Hook Health
Hooks: N total · Failing: A · Never-fired: B · Event-mismatch: C
Worst: <hookName>(F/T failed)
```

## Remediation order

1. `HOOK-FAILING` (Critical) → investigate the hook script; the audit cannot fix script logic.
2. `HOOK-EVENT-MISMATCH` → reconcile the registration in `settings.json` with where the hook actually fires.
3. `HOOK-NEVER-FIRED` → unregister or document why it's idle.
