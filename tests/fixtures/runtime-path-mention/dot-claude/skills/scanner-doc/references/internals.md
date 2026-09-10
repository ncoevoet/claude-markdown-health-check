# Internals

The history miner reads `~/.claude/projects/*/*.jsonl` and the skill ledger at `~/.claude.json`.
The graph scanner reads `~/.claude/plugins/installed_plugins.json` and writes to `~/.claude/.cache`.

These are runtime data paths the audit inspects — prose mentions, not chained skill references.
