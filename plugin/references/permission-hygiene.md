# Permission Allowlist Hygiene — Phase 15

Cross-references `settings.json#permissions.allow` against the cross-session denial count from `history-scan.json`. Runs at Standard + Deep depth.

## Source

- `~/.claude/settings.json` + `settings.local.json` — `.permissions.allow` arrays.
- `history-scan.json` → `.denials.count` (total cross-session tool denials in window — exact tool name is NOT captured because the JSONL `tool_result` text doesn't carry it reliably).

Because the per-tool denial breakdown is unavailable, Phase 15 only emits the coarser tags below. The `PERM-MISSING-ENTRY` heuristic (denied ≥5×) cannot fire and is parked.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `PERM-DEAD-ENTRY` | best-effort: allowlist entry whose tool name does not appear in any `tool_use` invocation in the window | Hygiene |
| `PERM-OVERBROAD` | entry uses `:*` AND its prefix matches fewer than 3 distinct in-window tool-use names | Hygiene |
| `PERM-MISSING-ENTRY` | parked until per-tool denial data is reachable | — |
| `SETTINGS-BYPASS-MODE` | `defaultMode` (or `permissions.defaultMode`) == `"bypassPermissions"`. In `~/.claude/settings.json` (user scope) it takes effect: every tool call is auto-approved with no prompt. In project or local settings it is ignored since v2.1.257 (the session starts in Manual mode), so it is reported as a warning (relayed from `validate-skills.sh`) | Critical at user scope, project/local = warning |
| `SETTINGS-MCP-AUTOAPPROVE` | `enableAllProjectMcpServers` == `true` — every project `.mcp.json` server is trusted without review (relayed from `validate-skills.sh`) | Hygiene |
| `SETTINGS-SANDBOX-OFF` | `sandbox.disabled` == `true` — tool calls run with no filesystem or network sandbox (relayed from `validate-skills.sh`) | Hygiene |
| `SETTINGS-AUTOMODE-BROAD` | an `autoMode.allow` entry wildcards a whole tool (`*`, `Bash`, `Bash(*)`) in the user settings file (`autoMode` is a user-or-managed key, so a project or local `autoMode.allow` is inert) while `permissions.disableAutoMode` is unset — auto mode then runs every matching command with no prompt (relayed from `validate-skills.sh`) | Hygiene |
| `SETTINGS-SCOPE-IGNORED` | a settings key, `env` variable or `defaultMode: "auto"` that Claude Code ignores in this file's scope (managed-only keys anywhere; user-or-managed keys in project/local; dropped `env` variables; see "Settings scope table") | Structural |
| `SETTINGS-DEPRECATED-KEY` | a deprecated or removed key is present (`includeCoAuthoredBy`, `disableArtifact`, `keybindingFlavor`, `voiceEnabled`, `permissionExplainerEnabled`, `taskOutputMaxChars`, `teammateDefaultModel`); the two "Global config" keys are also looked up in `~/.claude.json` in the user tree | Hygiene |
| `CLAUDEMD-EXCLUDE-DEAD` | a `claudeMdExcludes` pattern is relative (no tilde expansion is documented), an absolute literal path that does not exist, or (project/local files only) an absolute or `**` glob that matches no instruction file Claude Code loads (`CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.claude/rules/**/*.md`, and the user `~/.claude` equivalents); patterns containing `{` are skipped (brace expansion is not evaluated) | Hygiene |
| `WORKTREE-SPARSE-NO-CLAUDE` | `worktree.sparsePaths` is non-empty, has no `.claude` entry, and the repository root has a committed `.claude/`: a sparse worktree then lacks the committed settings and rules (untracked skills, agents and commands are still read from the main checkout) | Structural |

To compute `PERM-DEAD-ENTRY`: extract each entry's tool name (prefix before `(`), and check it against `history-scan.json` → `.toolCalls` keys. Entries with no matching key are dead.

## Settings scope table

`validate-skills.sh` holds the scope data and nothing else does: the arrays `SETTINGS_KEYS_MANAGED_ONLY`, `SETTINGS_KEYS_USER_OR_MANAGED` and `SETTINGS_KEYS_USER_LOCAL_MANAGED`, and the `env` expressions `SETTINGS_ENV_DROPPED_PROJECT_RE`, `SETTINGS_ENV_DROPPED_WINDOWS_RE` and `SETTINGS_ENV_DROPPED_ALL_RE` (read them there; this file deliberately names no keys so there is one source of truth).

Rules:
- Scope of a file: `user` when its directory is `~/.claude`, `local` for `settings.local.json`, else `project`. Managed settings are never scanned.
- Managed-only keys are ignored in every scanned file; user-or-managed keys are ignored in project and local files; the user/local/managed keys are ignored in project files only. Dotted entries are nested paths; a parent already listed makes its children redundant.
- `env` variables on the project-dropped list are ignored in project and local files; the every-file list is ignored everywhere. Windows names are case-insensitive, POSIX names are not. The only values still honoured from project/local files are the off values: `none` for `OTEL_(LOGS|METRICS|TRACES)_EXPORTER`, and `0`, `false`, `no` or `off` (any casing) for `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_TOOL_CONTENT` and `OTEL_LOG_TOOL_DETAILS`.
- The "Global config" keys of the scope column (`~/.claude.json`) are not scope-checked; only the removed ones are looked up there.

Refresh when `settings-reference` changes: regenerate the three arrays from its Scope column with
`awk '/^\| \[`/' settings-reference.md | sed -E 's/^\| \[`([^`]+)`\]\([^)]*\) \|.*\| ([^|]+) \|$/\2\t\1/'`.

## Report block

```
### Permission Hygiene
Allow: N entries · Dead: X · Overbroad: Y · Total denials: Z
```

## Remediation order

1. `SETTINGS-BYPASS-MODE` → at user scope, drop `bypassPermissions`; use `acceptEdits` or default mode, or set `disableBypassPermissionsMode` in managed settings. In a project or local file the value is already ignored: remove it, or move it to user or managed settings (or pass `--permission-mode`) if it was meant to apply.
2. `SETTINGS-MCP-AUTOAPPROVE` → set `enableAllProjectMcpServers` to false and allow-list specific servers via `enabledMcpjsonServers`.
3. `SETTINGS-SANDBOX-OFF` → drop `sandbox.disabled` and scope exceptions with `sandbox.filesystem` / `sandbox.network` instead of turning the sandbox off wholesale.
4. `SETTINGS-AUTOMODE-BROAD` → replace the wildcard with the specific commands auto mode should run, or set `permissions.disableAutoMode`.
5. `PERM-OVERBROAD` → tighten the matcher pattern (e.g., `Bash(cat:*)` → `Bash(cat ~/.claude/*)`).
6. `PERM-DEAD-ENTRY` → delete entries whose tool was never invoked in 30 days.
7. Review the raw `Total denials` count via the user's session log if it seems high — may indicate a missing allowlist entry.

## Inert rules

`validate-skills.sh` flags rules Claude Code accepts but never applies (`PERM-INERT-RULE`, Structural, in `allow`, `ask` and `deny`):

| Category | Example | Replacement |
|---|---|---|
| Path rule on a tool that is not consulted | `Write(src/**)`, `NotebookEdit(...)`, `MultiEdit(...)`, `Glob(secrets/**)` | `Edit(src/**)` covers every built-in editing tool; `Read(secrets/**)` covers Grep and Glob. Bare `Write` and `Write(*)` stay valid. |
| `mcp__` rule with parentheses | `mcp__srv__tool(arg)` | `mcp__srv__tool` or `mcp__srv__*` (skipped when the settings file loads) |
| `Tool(param:value)` | `Bash(command:rm *)`, `WebFetch(url:x)` | `Bash(rm *)`, `Read(./path)`, `WebFetch(domain:host)` |

`CLAUDEIGNORE-NO-EFFECT` (Hygiene, project tree only): permissions.md says "If your project has a `.claudeignore` file, it has no effect, so move its entries into `Read` deny rules." Replace each line with a `permissions.deny` `Read(...)` rule.
