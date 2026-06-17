# Hook Safety — Phase 14 (Hooks)

Static safety scan of hook scripts (`$CLAUDE_DIR/hooks/*.sh`) and http hook configuration in `settings.json` / `settings.local.json`. Deterministic — emitted by `validate-skills.sh`. Heuristics are deliberately **high-precision, low-recall**: each fires only on an unambiguous danger so well-formed hooks stay silent. Source: <https://code.claude.com/docs/en/hooks>.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `HOOK-EXIT-NONBLOCKING` | the script emits a block/deny decision (`"decision":"block"` or `"permissionDecision":"deny"`) yet contains `exit 1` and no `exit 2` — only **exit 2** blocks the action; exit 1 (and every other non-2 code) is non-blocking, so the guard silently does nothing | Structural |
| `HOOK-UNSAFE-SHELL` | the script runs `eval` on a dynamic value (`eval ...$...`) — tool input arrives on stdin untrusted; eval of it is a command-injection sink | Structural |
| `HOOK-ENV-LEAK` | an `http`-type hook carries an auth-bearing header (`Authorization`, an api-key/token/secret header, or a `${...}` interpolation) but sets neither per-hook `allowedEnvVars` nor top-level `httpHookAllowedEnvVars` — Claude Code then forwards the **entire environment** to the hook URL | Structural |
| `HOOK-NO-SHEBANG` | the hook script's first line is not a `#!` shebang | Hygiene |

Full-line comments (and the shebang) are stripped before the block/exit/eval heuristics run, so a documented or commented-out `eval "$x"` or sample block decision is not flagged. (An `eval $...` after an *inline* `#` on a line of real code is a known, accepted edge — contrived enough to leave to recall over precision.)

## Deliberately NOT checked

- **Executable bit.** Git and CI do not reliably preserve the `+x` bit, so checking it would produce environment-dependent false positives. The shebang check (content-based) is the robust proxy.
- **Broad unquoted `$VAR`.** Static detection of every unquoted expansion is far too false-positive-prone; only the unambiguous `eval $...` sink is flagged.

## Remediation order

1. `HOOK-EXIT-NONBLOCKING` → change the blocking branch to `exit 2` (the only exit code that blocks).
2. `HOOK-UNSAFE-SHELL` → never `eval` tool input; parse with `jq` and act on validated values, or use an allowlist.
3. `HOOK-ENV-LEAK` → add `allowedEnvVars` to the hook (or `httpHookAllowedEnvVars` in settings) listing only the vars the endpoint needs.
4. `HOOK-NO-SHEBANG` → add `#!/usr/bin/env bash` (or the correct interpreter) as the first line.
