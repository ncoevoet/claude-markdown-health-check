---
name: replayer
description: Replays recorded webhook payloads through the mapping layer and diffs the resulting billing events. Use when investigating a mis-billed tenant or verifying a mapping change.
---

# Replayer

A replay reads a recorded payload set, runs it through the current mapping, and
diffs the produced events against what was billed at the time.

## Using a replay

- Keys used for idempotency must exclude the delivery timestamp, or a retry looks new
- A diff with only ordering changes is expected: ordering is per-tenant, not global
