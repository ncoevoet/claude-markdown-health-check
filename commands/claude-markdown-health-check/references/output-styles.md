# Output-Style Hygiene — Phase 26

Audits `.claude/output-styles/*.md` against the selected `outputStyle` setting.
Output styles are a 2026 surface: per-session system-prompt presets, selected via
`settings.json#outputStyle` or interactively through `/config`. Runs at Standard +
Deep depth, any tree.

## Source

`scan-graph.sh` writes `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/graph-scan.json`.
Filter the findings array on `.phase == 26`.

- `$CLAUDE_DIR/output-styles/*.md` — the style files on disk.
- `settings.json` + `settings.local.json` → `.outputStyle` — the selected style name.
- Built-in styles (`Default`, `Proactive`, `Explanatory`, `Learning`) ship with
  Claude Code and have no file; selecting one (matched case-insensitively) is never
  a finding.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `OUTPUTSTYLE-MISSING` | `settings.json#outputStyle` names a style with no `output-styles/<name>.md` file, and the name is not a built-in style | Critical |

There is intentionally no "orphan style" tag: `/config` saves the active style to
`settings.local.json`, and users legitimately keep several style files as a palette
to switch between, so an unselected file is not a defect.

## Report block

```
### Output Styles
Styles: N on disk · Selected: <name|none> · Missing: X
```
Emit nothing when X=0.

## Remediation order

1. `OUTPUTSTYLE-MISSING` → create `output-styles/<name>.md`, fix the `outputStyle`
   value to an existing style, or switch to a built-in (`Default`/`Proactive`/`Explanatory`/`Learning`).
