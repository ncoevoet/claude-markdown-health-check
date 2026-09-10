---
name: safety
description: Documents safe cleanup patterns and guards the team against dangerous shell operations.
disallowed-tools: Bash(rm -rf *), Bash(git push --force)
---
# Safety

Configure a hook to block `rm -rf` before it runs; the matching pattern is `rm\s+-rf`.

To recover a dropped table on Snowflake, run `undrop table archived` — a non-destructive restore.
