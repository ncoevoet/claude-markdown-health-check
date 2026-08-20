# Agent Frontmatter Schema — Phase 14 (Agents)

Validates every subagent definition (`.claude/agents/*.md`, user and project trees) against the **subagent** frontmatter schema. Deterministic — emitted directly by `validate-skills.sh` during a dedicated `--- Agents ---` pass. No separate script, no JSON cache.

The subagent schema is distinct from the skill schema, so reusing the skill validator would mis-flag valid agent fields. Source: <https://code.claude.com/docs/en/sub-agents>.

## Subagent fields recognized

`name`, `description` (required for routing), `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`, `effort`, `isolation`, `color`, `initialPrompt`.

Key differences from skills: agents use `tools`/`disallowedTools` (not `allowed-tools`), add `permissionMode` and `color`, and the command name is the **filename** (no directory). The pass does **not** flag unknown keys — the subagent schema evolves quickly, so unknown-field detection would be a false-positive magnet.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `AGENT-BAD-SCHEMA` | missing `description`; OR `model` not in `{opus, sonnet, haiku, fable, inherit, claude-(opus\|sonnet\|haiku\|fable)-N}`; OR `color` not in `{red, blue, green, yellow, purple, orange, pink, cyan}`; OR `permissionMode` not in `{default, acceptEdits, auto, dontAsk, bypassPermissions, plan}`; OR `tools`/`disallowedTools` residue after stripping `Name` / `Name(args)` / `mcp__server__tool`; OR `name` not lowercase-hyphen | Critical |
| `AGENT-BYPASS-PERMS` | `permissionMode: bypassPermissions` (a valid value, but it disables every permission prompt for the agent) | Critical |
| `AGENT-DUP-NAME` | two agent files resolve to the same effective `name` — Claude Code silently discards one | Structural |

The filename is deliberately **not** checked against `name`: the sub-agents spec states the `name` field is the identifier and "the filename does not have to match" (e.g. `agents/01-injection.md` with `name: security-finder-injection` is valid).
| `AGENT-PLUGIN-FORBIDDEN-FIELD` | the scanned tree is a plugin (a `.claude-plugin/plugin.json` sits at the tree root) and an agent declares `hooks`/`mcpServers`/`permissionMode`, which plugin agents silently ignore | Structural |

## Scope note

`AGENT-PLUGIN-FORBIDDEN-FIELD` only fires when `validate-skills.sh` is pointed at a **plugin root** (`CLAUDE_DIR` contains `.claude-plugin/plugin.json`) — i.e. during plugin development. A normal `~/.claude` or project `.claude` tree is not a plugin, so its agents may legitimately use those fields and the check stays silent.

## Remediation order

1. `AGENT-BYPASS-PERMS` → drop `permissionMode: bypassPermissions` unless the agent genuinely needs unattended execution; prefer `acceptEdits` or `dontAsk`.
2. `AGENT-BAD-SCHEMA` (bad enum) → set a valid `model`/`color`/`permissionMode`, or drop the field to inherit.
3. `AGENT-DUP-NAME` → rename one agent so each `name` is unique across the tree.
4. `AGENT-PLUGIN-FORBIDDEN-FIELD` → move `hooks`/`mcpServers`/`permissionMode` to the plugin manifest / settings; they do nothing in a plugin agent file.
