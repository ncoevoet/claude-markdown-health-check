# Frontmatter Strict Schema — Phase 10

Validates the YAML frontmatter of every SKILL.md and command `.md` against a documented field set. Runs at every depth — cheap deterministic check inside `validate-skills.sh`.

Subagent files (`.claude/agents/*.md`) use a **distinct schema** (`tools`/`disallowedTools` instead of `allowed-tools`, plus `permissionMode`, `color`, `maxTurns`, …) and are validated by a separate pass — see [`agent-frontmatter.md`](agent-frontmatter.md). The agent pass emits its own tags (`AGENT-BAD-SCHEMA`, `AGENT-BYPASS-PERMS`, `AGENT-DUP-NAME`, `AGENT-PLUGIN-FORBIDDEN-FIELD`).

## Source

This phase is fully deterministic. `validate-skills.sh` emits the findings directly during its Skills + Commands passes. No separate script call. No JSON cache file.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `BAD-FRONTMATTER-SCHEMA` | description < 40 chars OR `model` value not in `{opus, sonnet, haiku, fable, inherit, claude-(opus\|sonnet\|haiku\|fable)-N}` OR `allowed-tools` has unparseable residue after stripping `Name` / `Name(args)` tokens | Critical |
| `UNKNOWN-FRONTMATTER-FIELD` | top-level key in frontmatter not in `{name, description, when_to_use, allowed-tools, argument-hint, model, color, user-invocable}` | Hygiene |

Existing tags `MISSING-DESC`, `DESCRIPTION-TOO-LONG`, `BAD-NAME`, `RESERVED-NAME`, `NAME-MISMATCH` continue to fire from `validate-skills.sh` per their original rules.

## Report block

None — findings flow directly into the flat tier list.

## Remediation order

1. `BAD-FRONTMATTER-SCHEMA` (description short) → rewrite to ≥40 chars with `[What] + [When to use] + [Key capabilities]`.
2. `BAD-FRONTMATTER-SCHEMA` (`model` invalid) → drop the field (inherits) or set to one of the allowed values.
3. `BAD-FRONTMATTER-SCHEMA` (`allowed-tools` malformed) → fix to space-separated `Name` or `Name(args)` tokens; nested parens are not allowed.
4. `UNKNOWN-FRONTMATTER-FIELD` → either remove the field or add it to the known set (the field may be a real Claude Code addition not yet listed).
