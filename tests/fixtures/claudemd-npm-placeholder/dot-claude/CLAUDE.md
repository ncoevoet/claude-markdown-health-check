# Demo app — Claude guide

Placeholder forms that are NOT script names and must never be flagged.

## Commands
- Per-app build: `npm run build:[project]` succeeds (Angular compilation)
- Alternation: `npm run oss|istra|inf|common:test`
- Permission glob: `Bash(npm run test:*)` and `Bash(npm run oss:test:*)`
- Angle placeholder: `npm run <app>:start:<profile>`

## Real commands
- Build the app: `npm run build:oss`
- Run the suite: `npm run oss:test`

## Architecture
- `src/` — application source
