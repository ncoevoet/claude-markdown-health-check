# /claude-markdown-health-check

A `.claude/` ecosystem auditor for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview). One slash command scans your skills, commands, hooks, agents, and settings — across both the user tree (`~/.claude`) and the project tree (`./.claude`) — and prints one flat, prioritized health report. It finds dead references, weak or mismatched triggers, token bloat, skill-listing-budget overflow, frontmatter violations, orphaned guides, and rule drift.

It reports first and waits. Nothing is edited, moved, or deleted until you reply naming which findings to fix — that autonomy gate is built into the command.

## What it checks

| Area | Examples of findings |
|---|---|
| **Skills** | descriptions missing a "when to use" half, triggers that don't match real usage, oversized `SKILL.md` with no `references/`, missing Examples / Troubleshooting sections, dead internal paths |
| **Skill-listing budget** | cumulative `description` + `when_to_use` block exceeding Claude Code's 1%-of-context budget; low-relevance and duplicate-domain skills |
| **Hooks** | files on disk not registered in `settings.json`, duplicate logic, suspicious timeouts, matchers that match no real tool |
| **Agents** | triggers unreachable from `CLAUDE.md`, overlapping agents |
| **Settings** | MCP servers missing from `preApprovedTools`, over-broad Bash patterns, stale reminders |
| **Cross-references** | dead paths in `settings.json` / `CLAUDE.md` / skill `references/`, orphaned guides and patterns, missing triggers |
| **Memory** | `MEMORY.md` over the loaded-slice line/byte budget |

Thresholds — line counts, description caps, budget fractions, hook timeouts — are pulled live from the official Anthropic docs and cached for a week, so the audit tracks the spec instead of hardcoding it.

## Severity tiers

- **Critical** — broken; blocks correct behavior (dead refs, unregistered hooks, budget overflow)
- **Structural** — works but should be reorganized (weak descriptions, orphans, trigger mismatches)
- **Hygiene** — cosmetic / token efficiency (over-broad patterns, stale reminders)
- **Discovery** — additive suggestions surfaced from the current session (new rules, patterns, triggers)

## Install

```bash
git clone https://github.com/ncoevoet/claude-markdown-health-check.git
cd claude-markdown-health-check
make install
```

`make install` copies three things into `~/.claude/`:

- `commands/claude-markdown-health-check.md` → `~/.claude/commands/`
- the reference docs → `~/.claude/claude-markdown-health-check/references/`
- `validate-skills.sh` → `~/.claude/commands/scripts/`

`make uninstall` removes the command and its reference tree. The bundled `validate-skills.sh` is left in place — it lives in a shared directory and other commands may depend on it.

This command works in Claude Code only — it depends on filesystem access and bash.

## Use

Inside Claude Code:

```
/claude-markdown-health-check
```

| Argument | Effect |
|---|---|
| _(empty)_ | Audits both `~/.claude` and any `./.claude`; depth auto-selected from ecosystem size |
| `quick` | Fast pass — validator + budget audit + spot-check the 3 highest-risk skills |
| `deep` | Full audit plus session analytics and a token deep-dive |
| `--refresh` | Re-fetch threshold values from the Anthropic docs instead of using the week-long cache |
| _any other text_ | Treated as a focus message — that topic becomes the #1 priority, and the session is scanned for violations of it |

Examples:

```
/claude-markdown-health-check
/claude-markdown-health-check quick
/claude-markdown-health-check deep
/claude-markdown-health-check --refresh
/claude-markdown-health-check check that every skill has a Troubleshooting section
```

The report prints in chat. Reply naming the findings to fix and the command applies them; until then it touches nothing.

## How it works — phases

| Phase | What it does |
|---|---|
| 1 — Thresholds | Fetches skill / memory / settings / hooks limits from the Anthropic docs; caches them at `~/.claude/.cache/claude-markdown-health-check-guidance.json` |
| 2 — Depth | Picks Quick / Standard / Deep from the argument and the size of your ecosystem |
| 3 — Focus + history | Reads the focus message (if any) and mines the current session for recurring bugs, corrections, and uncovered patterns |
| 4 — Validator | Runs `validate-skills.sh` per scope — the deterministic layer (name regex, line counts, voice, TOC, description sizes) |
| 5a — Listing budget | Audits the cumulative skill-listing block against Claude Code's runtime budget |
| 5 — Skill semantics | Judgment-call checks the validator can't do — trigger quality, structure, resolvability |
| 6 — Hooks / agents / settings | Registration, duplication, timeouts, broad patterns, stale reminders |
| 7 — Cross-refs + orphans | Dead paths, orphaned guides/patterns, missing triggers, memory-index overflow |
| 8 — Report | One flat prioritized report: Critical · Structural · Hygiene · Discovery |

## Requirements

- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code/overview)
- `bash`, `awk`, `grep`, `find` (defaults on macOS/Linux)
- `jq` — optional; sharpens the skill-listing-budget read of `settings.json`

## Layout

```
commands/
├── claude-markdown-health-check.md          # the slash command
├── claude-markdown-health-check/
│   └── references/
│       └── skill-listing-budget.md          # Phase 5a audit logic
└── scripts/
    └── validate-skills.sh                   # deterministic compliance validator
```

All plain Markdown and shell — read, fork, extend.

## License

MIT — see [LICENSE](LICENSE).
