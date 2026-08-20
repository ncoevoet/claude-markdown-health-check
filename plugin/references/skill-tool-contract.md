# Skill–Tool Contract — Phase 9

Compares each skill's declared `allowed-tools` against the tools it actually invokes across the 30-day window. Runs at Standard + Deep depth.

## Source

`history-scan.json` (from `scan-history.sh`). Sections used:
- `.skills[<name>].invokes` → must be ≥3 for a skill to contribute signal.
- `.toolCalls` → in-window tool-use counts.

The in-line filter does NOT scope tool calls to a specific skill turn — limiting the contract to skills with ≥3 invokes lowers false positives without requiring expensive turn-segmentation in bash.

## Variables (per skill `s` with ≥3 invokes)

- `declared(s)` = the tokens in the skill's `allowed-tools` frontmatter (parsed via `validate-skills.sh`'s schema check).
- `called(s)` = approximate tool-call multiset for sessions where `s` was invoked.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `SKILL-TOOL-UNUSED` | tool in `declared(s)` but never appears in `called(s)` | Hygiene |
| `SKILL-TOOL-UNDECLARED` | tool in `called(s)` but not in `declared(s)` (triggers permission prompts at runtime) | Structural |

A skill with no `allowed-tools` frontmatter is exempt — it implicitly inherits all tools.

## Report block

Folded into the per-skill detail block of Phase 7 — no separate Phase 9 header.

## Remediation order

1. `SKILL-TOOL-UNDECLARED` → add the missing tool to the skill's `allowed-tools`.
2. `SKILL-TOOL-UNUSED` → trim the unused tool from `allowed-tools` (reduces skill-listing weight).
