# Notes service — Claude guide

A small notes API. Use the commands below; they are wired to real scripts in this
config.

## Commands
- Lint the notes skill: `bash skills/notes/scripts/check.sh`
- Build & test: `make build && make test`

## Architecture
- `skills/notes/` — the notes-management skill (entry point for all note ops)
- `skills/notes/scripts/` — helper scripts the skill shells out to

When the user works on notes, prefer the `notes` skill over ad-hoc edits.
