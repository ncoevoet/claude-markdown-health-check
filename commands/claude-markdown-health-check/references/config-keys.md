# Config Keys — `.claude/markdown-health-check.json`

Per-key reference for the optional audit config. All keys are optional; the default
applies when a key is absent.

**Load order & precedence:** `~/.claude/markdown-health-check.json` (user defaults)
is merged with `./.claude/markdown-health-check.json` (project overrides win key by
key). A CLI argument always wins over both — e.g. `--window-days=14` overrides
`windowDays`, and `quick`/`deep` override `depth`. So precedence is **CLI > project
config > user config > default**.

Each default carries a **Why** — Ousterhout's law: no voodoo constants. Most tuning
is also reachable via CLI flags; the config file just makes a choice persistent.

## Keys

| Key | Type | Default | Meaning | Why this default |
|-----|------|---------|---------|------------------|
| `windowDays` | `number` | `30` | History window (days) for the telemetry phases (7, 9, 15, 16, 19, 22, 23) that read `history-scan.json`. Same knob as `--window-days=N`. | A month captures monthly-cadence skills and hooks without over-weighting activity that has already aged out of relevance. |
| `depth` | `"auto"\|"quick"\|"standard"\|"deep"` | `"auto"` | Depth floor / override. `auto` picks Quick/Standard/Deep from ecosystem size (Phase 3); the others pin it. `quick`/`deep` CLI args override this. | `auto` is least-surprising — a small tree gets a fast pass, a large one a full audit, with no config needed. |
| `verifyFindings` | `boolean` | `true` | Run the Pre-print evidence-grounding gate (`finding-verification.md`) over judgment findings. `false` emits judgment findings unverified. | Precision-by-default: an ungrounded finding is the one a user disputes. `false` exists only as a debugging escape hatch when you want to see the raw judgment output. |
| `skipPhases` | `number[]` | `[]` | Phase numbers to skip entirely (e.g. `[23]` to drop the token-trend phase). Deterministic Phase 5 cannot be skipped — it is the spine. | Empty default: opt-in suppression only. Nothing is hidden unless the user asks. |
| `compressBodies` | `boolean` | `false` | Persistent equivalent of `--compress-bodies` (Phase 13 opt-in body rewrite). | `false`: the body rewrite edits files and lands a branch, so it must be explicitly requested, never a silent default. |
| `severityFloor` | `"must-fix"\|"should"\|"polish"` | `"polish"` | Lowest chip to include in the report. `"should"` hides `[polish]`; `"must-fix"` hides `[polish]` and `[should]`. Discovery `[idea]` items are unaffected. | `"polish"` shows everything — the user sees the full picture by default and opts into a quieter report per repo. |
| `maxFindingsPerDomain` | `number` | `0` | Cap on findings shown per report domain (Skills, Hooks, …); excess lowest-severity items are summarised as a count. `0` = unlimited. | `0` never hides a real finding for noise reasons (mirrors the auditor's bias toward completeness); raise it only when a domain is genuinely flooded. |
| `guidanceCacheTtlDays` | `number` | `7` | TTL (days) for the Phase 1 threshold cache before it re-fetches the Anthropic docs. `--refresh` forces a re-fetch regardless. | The documented limits change rarely; a weekly re-fetch balances freshness against paying 5 WebFetches on every run. |

## Notes

- Keys not listed above are ignored. Forward-compatible: future keys can be added
  without breaking old configs.
- `markdown-health-check.json` is a distinct file from `settings.json`, so the
  settings phases never parse it and never flag its keys.
- The config tunes the audit run; it is never itself a finding. A malformed config
  (invalid JSON) is reported once as `[OBSERVATION] config: markdown-health-check.json
  is not valid JSON — using defaults`, then ignored.
