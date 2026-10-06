# Frontmatter Strict Schema — Phase 10

Validates the YAML frontmatter of every SKILL.md and command `.md` against a documented field set. Runs at every depth — cheap deterministic check inside `validate-skills.sh`.

Subagent files (`.claude/agents/*.md`) use a **distinct schema** (`tools`/`disallowedTools` instead of `allowed-tools`, plus `permissionMode`, `color`, `maxTurns`, …) and are validated by a separate pass — see [`agent-frontmatter.md`](agent-frontmatter.md). The agent pass emits its own tags (`AGENT-BAD-SCHEMA`, `AGENT-BYPASS-PERMS`, `AGENT-DUP-NAME`, `AGENT-PLUGIN-FORBIDDEN-FIELD`).

## Source

This phase is fully deterministic. `validate-skills.sh` emits the findings directly during its Skills + Commands passes. No separate script call. No JSON cache file.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `BAD-FRONTMATTER-SCHEMA` | `model` value not in `{opus, sonnet, haiku, fable, inherit, claude-(opus\|sonnet\|haiku\|fable)-N}` OR `allowed-tools` has unparseable residue after stripping `Name` / `Name(args)` tokens | Critical |
| `DESC-TOO-SHORT` | SKILL.md `description` under 40 chars — advisory only; the docs mark `description` "Recommended" and set no floor, so this is a trigger-reliability nudge, not a schema violation. Command files are exempt (user types `/name`) | Hygiene |
| `DESC-XML-TAG` | SKILL.md `description` contains an XML-style tag (`<b>`, `</x>`, `<br />`, `<example name="a">`, `<iid>`) or a generic type with a comma list (`Map<K,V>`); the docs forbid it because the description is injected into the system prompt. Bare tags only: `x<y and y>z` does not match. Command files are exempt | Critical |
| `WINDOWS-PATH` | backslash file path with an extension (`scripts\helper.py`) in a SKILL.md or skill reference, outside fenced code (``` and ~~~) | Structural |
| `TIME-SENSITIVE` | `before`/`after`/`until`/`as of`/`since` + month + year (`before August 2025`, `until 5 Mar 2026`) in a SKILL.md or skill reference, outside fenced code, `<details>` and Old patterns / legacy / deprecated sections | Hygiene |
| `VAGUE-NAME` | skill name is a bare generic word (`helper`, `utils`, `tools`, `document`, `data`, `files`), or a skill reference file is `doc<N>.md` / `file<N>.md` | Hygiene |
| `RESERVED-WORD-PORTABILITY` | skill name contains `anthropic` or `claude` (case-insensitive substring, so `claudette` also fires) | Hygiene |
| `UNKNOWN-FRONTMATTER-FIELD` | top-level key in frontmatter not in `{name, description, when_to_use, allowed-tools, disallowed-tools, argument-hint, arguments, model, color, user-invocable, disable-model-invocation, effort, context, agent, hooks, paths, shell, hide-from-slash-command-tool, background, metadata, license, compatibility}` — the last four are Agent Skills spec / `context: fork` fields Claude Code accepts | Hygiene |

Existing tags `MISSING-DESC`, `DESCRIPTION-TOO-LONG`, `BAD-NAME`, `NAME-MISMATCH` continue to fire from `validate-skills.sh` per their original rules.

`RESERVED-NAME` fires on the one name the docs reserve: a skill **directory** called `synced`, in any capitalization, in the enterprise, personal or project skills location. It is the folder that is reserved, not the frontmatter `name`. `RESERVED-NAME` is unchanged, and Claude Code itself accepts `claude-api`, but the Agent Skills API / claude.ai upload rejects names containing `anthropic` or `claude`, so a name containing `anthropic`/`claude` (case-insensitive substring) emits the Hygiene hint `RESERVED-WORD-PORTABILITY` (never an error).

## Report block

None — findings flow directly into the flat tier list.

## Remediation order

1. `BAD-FRONTMATTER-SCHEMA` (`model` invalid) → drop the field (inherits) or set to one of the allowed values.
2. `BAD-FRONTMATTER-SCHEMA` (`allowed-tools` malformed) → fix to space-separated `Name` or `Name(args)` tokens; nested parens are not allowed.
3. `UNKNOWN-FRONTMATTER-FIELD` → either remove the field or add it to the known set (the field may be a real Claude Code addition not yet listed).
4. `DESC-TOO-SHORT` → optional. If the skill is meant to be model-picked, rewrite to ≥40 chars with `[What] + [When to use] + [Key capabilities]`; a deliberately terse description is not a defect.
5. `DESC-XML-TAG` → remove or replace the tag in the description (write the placeholder as plain words).
6. `WINDOWS-PATH` → use forward slashes (`scripts/helper.py`).
7. `TIME-SENSITIVE` → move the legacy behaviour under an "Old patterns" section, or drop the date.
8. `VAGUE-NAME` → rename the skill or reference file descriptively (`processing-pdfs`, `form_validation_rules.md`).
9. `RESERVED-WORD-PORTABILITY` → rename only if the skill will be uploaded to the API or claude.ai.
