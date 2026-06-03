# Project guide

This service ships through a structured release flow. Before promoting a build,
follow the full checklist in `documentation/guides/deployment.md`.

## Build & test
- Build: `make build`
- Test: `make test`

## Architecture
- `documentation/guides/` — operational runbooks (deployment, rollback)
- `skills/` — project-specific Claude skills
