# Plugin Skill Risk Indicators

Emitted by `validate-skills.sh` for skills and commands installed through plugins (`~/.claude/plugins/installed_plugins.json`, user tree only). Source: the enterprise skill review checklist (<https://platform.claude.com/docs/en/agents-and-tools/agent-skills/enterprise>), whose risk indicators are network calls, path traversal and "instructions that ... ignore safety rules or hide actions from users". They are indicators for a human reviewer, not verdicts: all are Discovery tier, reported as suggestions.

## Why own-tree skills are exempt

The checklist is a vetting procedure for third-party skills. A skill in the user's own `~/.claude/skills` or a project's `.claude/skills` was written or reviewed by its owner, so flagging its `curl` calls would be noise. Only plugin-installed skills are checked.

## Tags

| Tag | Fires when |
|---|---|
| `SKILL-NETWORK-SURFACE` | a bundled `*.py`, `*.sh`, `*.js`, `*.mjs`, `*.ts` or `*.ps1` script makes a network call (`curl`, `wget`, `fetch(`, `requests.*`, `urllib.request`, `httpx.`, `urlopen(`, `https.get(`, `Invoke-WebRequest`, `Invoke-RestMethod`, `iwr`, `XMLHttpRequest`, `WebSocket`). Comment lines are ignored. One finding per script |
| `SKILL-HIDDEN-BEHAVIOR` | SKILL.md or a plugin command tells the model not to tell/inform/notify the user, to hide something from the user, to ignore safety/system instructions, or names a `../` path that leaves the plugin directory |
| `SKILL-MCP-REFERENCE` | SKILL.md or a plugin command references an MCP tool as `ServerName:tool_name` ("extends access beyond the Skill itself"). Judge whether the skill's stated purpose needs that server |

## Scope

Roots scanned per plugin: `skills/`, plus every `skills` entry of `.claude-plugin/plugin.json` (each a directory of `<name>/SKILL.md` folders or one folder holding `SKILL.md` directly; `"."` is the plugin root), and `commands/*.md` plus manifest `commands` entries. Manifest entries that are absolute or contain `..` are skipped (a different check owns those). A `../` is flagged only when its lexical resolution leaves the plugin root; the root itself is allowed, and the install path is resolved physically first so a symlinked install is handled.

## Remediation

Read the flagged script or sentence. If it is expected for the plugin's purpose, accept it; otherwise disable the plugin (`enabledPlugins`) or remove the skill.
