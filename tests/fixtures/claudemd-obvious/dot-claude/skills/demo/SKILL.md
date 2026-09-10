---
name: demo
description: Syncs pricing tables between the catalogue and the billing system. Use when a price change must be propagated or a sync run has to be replayed.
---

# Demo

The sync reads the catalogue export, diffs it against the billing snapshot, and
writes one change record per differing row.
