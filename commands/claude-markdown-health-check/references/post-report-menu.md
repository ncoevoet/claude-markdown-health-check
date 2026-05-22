# Post-Report Menu

Loaded by `/claude-markdown-health-check` Phase 9. After the report prints, this turns the passive "wait for the user" step into an explicit action menu.

## When to show

- Show the menu only when the report has at least one actionable finding (Critical, Structural, or Hygiene). If every section is empty, print "No findings — ecosystem is healthy." and stop; no menu.
- `Discovery` items (`NEW-*`) and `OBSERVATION` lines are informational — they do not by themselves trigger the menu.

## Primary menu (single-select, via `AskUserQuestion`)

`AskUserQuestion` caps at 4 options. Build the list dynamically — include only the tiers that actually have findings:

| Label | Offer when | Action |
|-------|-----------|--------|
| **Fix Critical (recommended)** | >=1 Critical finding | Apply every Critical `Proposed Change` |
| **Fix Critical + Structural** | >=1 Critical or Structural finding | Apply Critical + Structural changes |
| **Fix everything** | >=1 finding of any tier | Apply all `Proposed Changes` |
| **Choose findings** | always, when any finding exists | Free-text via `Other` — name tiers, tags, or finding numbers; apply the union |

If only one tier has findings the first three collapse — still offer the one relevant "Fix ..." option plus "Choose findings". Never build one option per finding (the 4-option cap makes that crash on large reports) — use the free-text `Choose findings` option instead.

## Applying fixes

For each finding in the chosen scope, in file-then-line order:
1. `Read` the target file before any `Edit` — the Edit tool requires a prior Read.
2. Apply the `Proposed Change` exactly as the report described it.
3. A `REPURPOSE` item: write the destination `references/<name>.md` AND update the source skill's References section BEFORE deleting the orphan.
4. If a change is not a single safe edit — architectural, cross-file, ambiguous — record it as `manual follow-up`; do not guess.

Guardrails:
- Edit only files inside the audited ecosystem trees (skills, hooks, settings, guides, patterns, references, and the project CLAUDE.md). Never touch anything else.
- Never delete a file the user did not approve via the chosen scope.
- A change needing a new file or a destructive rewrite is `manual follow-up`, never automatic.

## After applying

1. Re-run `validate-skills.sh` for each affected scope; report the new error / warning counts.
2. Print a one-line-per-finding outcome table: `applied` / `manual follow-up` / `skipped`.
3. Re-present the menu with the findings still outstanding (the loop). Once a fix round has run, always include a `Done` option; when the user picks it, stop.

## Loop

After any non-terminal choice, re-present the menu with updated state until the user selects `Done`. Each round operates only on the findings still outstanding.
