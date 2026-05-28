# Reference Graph Health — Phase 11

Builds the `references/*.md` link graph rooted in every SKILL.md and command `.md`. Flags cycles, excessive depth, and orphan ref files. Runs at Standard + Deep depth.

## Source

`scan-graph.sh` writes `graph-scan.json`. Filter on `.phase == 11`.

## Variables

- `MAX_REF_DEPTH` = `${MAX_REF_DEPTH:-3}` (env-tunable hard cap). Note the
  [skill best-practice](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices):
  references should sit **one level deep** from SKILL.md — depth 1 is ideal, and
  the cap is a backstop, not a target.
- Graph nodes: every SKILL.md, every command `.md` (the "roots"), and every file under a sibling `references/` directory (the "ref leaves").
- Graph edges: any `references/foo.md` substring inside a node's body, resolved against the node's reference base. A reference file's own citations resolve against the OWNING skill/command root (the dir containing `references/`), so a ref citing a sibling ref builds a real edge instead of doubling the path — this is what makes `REF-CIRCULAR`/`REF-TOO-DEEP` reachable and stops a cited sibling being mislabelled `REF-ORPHAN`.

> Follow-up (not yet implemented): CLAUDE.md `@path` imports have a separate hard limit of **4 hops** per the [memory doc](https://code.claude.com/docs/en/memory); a dedicated `@import`-depth check could live here.

## Tags

| Tag | Condition | Tier |
|---|---|---|
| `REF-CIRCULAR` | DFS from a root re-enters a node already in the active stack | Critical |
| `REF-TOO-DEEP` | shortest-path from any root > `MAX_REF_DEPTH` | Structural |
| `REF-ORPHAN` | ref file with in-degree 0 | Hygiene |

Cycle detection uses bash-side associative arrays and reports the FIRST cycle hit per node; subsequent cycles via the same node are suppressed.

## Report block

```
### Reference Graph
Roots: X · Refs: Y · Cycles: A · Too-deep: B · Orphan: C
```
Emit nothing when A=B=C=0.

## Remediation order

1. `REF-CIRCULAR` → break the cycle by inlining one side or removing a back-reference.
2. `REF-TOO-DEEP` → flatten — pull deeply nested content one level closer to the root.
3. `REF-ORPHAN` → either reference the file from the owning SKILL.md or delete it.
