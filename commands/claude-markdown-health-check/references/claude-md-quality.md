# CLAUDE.md Content Quality

Loaded by `/claude-markdown-health-check` Phase 12. Phase 1 already checks CLAUDE.md *size* and `validate-skills.sh` checks its *dead links*; this rubric judges whether the file is actually *useful* to a fresh Claude session.

## What a good CLAUDE.md contains

A CLAUDE.md earns its context budget when it captures what a new session cannot infer from the code in a few minutes:

| Dimension | Good looks like |
|---|---|
| Commands & workflows | Real build / test / lint / run commands, copy-paste ready |
| Architecture map | Directories, module relationships, entry points, data flow |
| Non-obvious patterns | Gotchas, quirks, workarounds, and the reasoning behind unusual choices |
| Conciseness | One concept per line; dense, no filler |
| Currency | Commands work today; file paths and tech versions are current |
| Actionability | Executable steps, not vague advice |

## Red flags

- A build command that no longer works, a referenced script/file that was deleted or renamed, or a tech version that no longer matches the repo — `CLAUDEMD-STALE`. (The validator already covers dead dot-claude links; this is for commands, scripts, and other paths.)
- Generic boilerplate that would apply to any project — "write clean code", "follow best practices", framework descriptions copied from upstream docs — `CLAUDEMD-GENERIC`.
- No build/test/run commands, or no architecture map at all — too thin to help — `CLAUDEMD-THIN`.

## Verify before flagging

- Mentally execute (or run, read-only) each command against the real tree.
- Resolve every path the file names; flag the ones that miss.
- Compare version numbers / tool names against `package.json`, `pom.xml`, lockfiles.
- Judge "generic" by asking: would this sentence be true for an unrelated repo? If yes, it is filler.

## Do NOT flag

- A short CLAUDE.md is fine when every line is project-specific and current — brevity is not a defect.
- Style or wording nits — only flag content that is wrong, stale, generic, or absent.
- `CLAUDE.local.md` personal-preference content — judge it the same way, but never propose committing it.
