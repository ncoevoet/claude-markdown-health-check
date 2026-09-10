# Deployment runbook

The release checklist referenced from `CLAUDE.md`. This guide is reachable from the
project instructions, so it is NOT orphaned.

## Steps
1. Tag the release commit (`vX.Y.Z`).
2. Build the artifact and run the smoke suite.
3. Promote to staging; wait for the health probe to go green.
4. Promote to production; watch error rates for 15 minutes.

## Rollback
Re-point the active alias to the previous tag and re-run the smoke suite.
