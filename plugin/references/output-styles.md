# Output-Style Hygiene — Phase 26

Audits `.claude/output-styles/*.md` against the selected `outputStyle` setting.
Output styles are a 2026 surface: per-session system-prompt presets, selected via
`settings.json#outputStyle` or interactively through `/config`. Runs at Standard +
Deep depth, any tree.

## Source

`scan-graph.sh` writes `${CLAUDE_PLUGIN_DATA:-~/.claude/.cache}/graph-scan.json`.
Filter the findings array on `.phase == 26`.

- `$CLAUDE_DIR/output-styles/*.md` — the style files on disk. A style is named by its
  frontmatter `name:`, else its file name. In a plugin root, `plugin.json` `outputStyles`
  (files or directories) replaces the default `output-styles/` scan.
- Styles also load from the user tree, every ancestor `.claude/output-styles/` up to the
  repository root, and (user tree) each installed plugin; they all resolve a selection.
- `settings.json` + `settings.local.json` → `.outputStyle` — the selected style name.
- Built-in styles are exactly `Default`, `Proactive`, `Concise`, `Explanatory`, `Learning`
  (`Concise` needs Claude Code v2.1.237) and have no file. Matching is case-sensitive; the
  one tolerated lowercase spelling is `default`, which `/output-style` lists as an entry.
- Style files are read at startup: restart after editing.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `OUTPUTSTYLE-MISSING` | `settings.json#outputStyle` names no style: not a built-in and no `output-styles/*.md` with that file name or frontmatter `name:` | Critical |
| `OUTPUTSTYLE-CASE` | the value equals a built-in or a style name only case-insensitively (`explanatory`): Claude Code falls back to Default | Structural |
| `OUTPUTSTYLE-BAD-YAML` | frontmatter never closes, has a tab-indented line, or an unquoted value containing `: `; the style loads under its file name with no fields (heuristic, not a YAML parser) | Structural |
| `OUTPUTSTYLE-UNKNOWN-FIELD` | a frontmatter key outside `name`, `description`, `keep-coding-instructions`, `force-for-plugin`; ignored silently (did-you-mean for `keep_coding_instructions`) | Hygiene |
| `OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN` | `force-for-plugin` in a style of a tree that is not a plugin root: inert | Hygiene |

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
   value to an existing style, or switch to a built-in (`Default`/`Proactive`/`Concise`/`Explanatory`/`Learning`).
2. `OUTPUTSTYLE-CASE` → write the exact spelling the finding names.
3. `OUTPUTSTYLE-BAD-YAML` / `OUTPUTSTYLE-UNKNOWN-FIELD` → fix the key, quote the value or
   use a block scalar (`description: >`).
4. `OUTPUTSTYLE-FORCE-OUTSIDE-PLUGIN` → remove the key or move the style into a plugin.
