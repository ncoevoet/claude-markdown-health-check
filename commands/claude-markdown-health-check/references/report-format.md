# Report format — domain-grouped + scorecard

How Phase 24 renders findings for humans. **Tags are the stable machine key**
(scripts emit them, the eval harness asserts on them); this layer is only the
human projection. Every finding still carries its tag — as a trailing code, not
the lead.

## Contents
- Severity chips
- Domain grouping + tag→domain map
- Scorecard
- Per-finding rendering
- Finding numbering
- Worked example

## Severity chips

The four severity tiers map to plain-language chips:

| Tier (internal) | Chip | Meaning |
|-----------------|------|---------|
| Critical | `[must-fix]` | broken; blocks correct behaviour |
| Structural | `[should]` | works but should be reorganised |
| Hygiene | `[polish]` | cosmetic / token efficiency |
| Discovery | `[idea]` | additive suggestion from this session |

## Domain grouping

Findings are grouped by the AREA they concern, in this fixed order (omit any
domain with zero findings):

`Skills` · `Hooks` · `Agents` · `Settings & Permissions` · `Memory` ·
`References` · `Plugins` · `CLAUDE.md` · `Rules` · `Context` · `Cross-session`

Discovery findings (`[idea]`) go in a trailing **Suggestions** section, not a domain.

### Tag → domain map

- **Skills** — `MISSING-DESC` `WEAK-DESC` `UNDER-TRIGGER` `OVER-TRIGGER` `NEEDS-REFERENCES` `NO-EXAMPLES` `NO-TROUBLESHOOTING` `BURIED-CRITICAL` `BAD-NAME` `NAME-MISMATCH` `BAD-FRONTMATTER-SCHEMA` `UNKNOWN-FRONTMATTER-FIELD` `THIRD-PERSON` `DESCRIPTION-TOO-LONG` `SKILL-BUDGET-OVERFLOW` `SKILL-LOW-RELEVANCE` `SKILL-DUPLICATE-DOMAIN` `SKILL-NEVER-FIRED` `SKILL-DORMANT` `SKILL-MISFIRING` `SKILL-ORPHAN` `SKILL-TOOL-UNUSED` `SKILL-TOOL-UNDECLARED` `NAME-COLLISION` `EMBEDDED-SECRET` `UNFLAGGED-DESTRUCTIVE` `BODY-FILLER-HIGH` `BODY-COMPRESSED` `BODY-COMPRESSION-REJECTED` `RESERVED-NAME` `OVER-500-LINES` `NO-PROGRESSIVE-DISCLOSURE` `DESCRIPTION-TOO-LONG` `DESCRIPTION-TRUNCATED` + a `DEAD-REF` whose path is a skill's own `references/`
- **Hooks** — `UNREGISTERED-HOOK` `SUSPICIOUS-TIMEOUT` `DUPLICATE-LOGIC` `MISSING-ENFORCEMENT` `DEAD-MATCHER` `HOOK-FAILING` `HOOK-NEVER-FIRED` `HOOK-EVENT-MISMATCH`
- **Agents** — `MISSING-AGENT-TRIGGER` `OVERLAPPING-AGENT` `AGENT-NEVER-SPAWNED`
- **Settings & Permissions** — `INVALID-JSON` `DUPLICATE-KEY` `DUPLICATE-ENTRY` `MISSING-PRE-APPROVED` `BROAD-PATTERN` `STALE-REMINDER` `PERM-DEAD-ENTRY` `PERM-OVERBROAD`
- **Memory** — `MEMORY-OVERFLOW` `MEMORY-DEAD-LINK` `MEMORY-ORPHAN-FILE` `MEMORY-DUP-ENTRY` `MEMORY-STALE-DATE`
- **References** — `REF-CIRCULAR` `REF-TOO-DEEP` `REF-ORPHAN` `CHAINED-REF` `MISSING-TOC` `ORPHAN-GUIDE` `ORPHAN-PATTERN` `REPURPOSE` `MISSING-TRIGGER` + a `DEAD-REF` to a guide/settings path
- **Plugins** — `PLUGIN-BROKEN-REF` `PLUGIN-MISSING-MANIFEST` `PLUGIN-VERSION-DRIFT`
- **CLAUDE.md** — `CLAUDEMD-STALE` `CLAUDEMD-GENERIC` `CLAUDEMD-THIN`
- **Rules** — `BAD-RULE-FRONTMATTER` `RULE-OVERSIZED`
- **Context** — `LOW-CACHE-HIT` `CONTEXT-BLOAT`
- **Cross-session** — `RECURRING-DENIAL` `RECURRING-CORRECTION` `MISSING-SKILL-GAP`
- **Suggestions** (Discovery) — `NEW-RULE` `NEW-PATTERN` `NEW-TRIGGER` `NEW-REFERENCE` `SKILL-UPDATE`

Audit-meta tags `STALE-THRESHOLD` and `GUIDANCE-FETCH-FAILED` print once at the top under `> audit note:` (they describe the audit run, not the user's tree).

## Scorecard

First line, per scope: an overall letter grade + per-domain issue counts (only
domains with ≥1 finding). Grade from the must-fix (M) and should (S) counts:

| Grade | Condition |
|-------|-----------|
| A | M = 0 and S ≤ 2 |
| B | M = 0 and S > 2 |
| C | 1 ≤ M ≤ 4 |
| D | M ≥ 5 |

```
.claude health (user) — grade B
issues: Skills 3 · Hooks 1 · Settings 1 · Memory 0 · Plugins 0
```

## Per-finding rendering

Two lines per finding: a plain-language sentence (chip first), then the locator
indented, with the tag trailing after ` · `:

```
 [must-fix] <plain sentence describing the problem in human terms>
            <path/locator>                                    · TAG
```

- Lead with what's wrong in plain words; the reader should understand without
  knowing the tag vocabulary.
- Within a domain, order findings `[must-fix]` → `[should]` → `[polish]`.
- Keep the tag — it is the stable machine code (and what the eval harness checks).

## Finding numbering

Number findings **1..N globally**, in reading order (domains in the fixed order
above; within a domain, by chip severity). The Phase 25 menu references these
numbers ("fix finding 4") and chips ("fix all must-fix"), so numbering must be
continuous across the whole report, not per-domain.

## Worked example

```
## .claude health (user) — grade B
issues: Skills 3 · Hooks 1 · Settings & Permissions 1

## Skills
 1. [must-fix] atlassian links to a missing file (references/api.md)
               skills/atlassian/SKILL.md                          · DEAD-REF
 2. [should]   atlassian body is 412 lines with no references/ split
               skills/atlassian/SKILL.md                   · NEEDS-REFERENCES
 3. [should]   atlassian is unused in the last 30 days but loads 4.2k chars each session
               skills/atlassian                               · SKILL-DORMANT

## Hooks
 4. [must-fix] the Edit hook fails on almost every run (284/304, 93%)
               PreToolUse:Edit                                  · HOOK-FAILING

## Settings & Permissions
 5. [polish]   Bash(cat:*) lets any file be read — scope it to ~/.claude
               settings.json                                   · BROAD-PATTERN
```

When two scopes are present, print one scorecard + grouped block per scope,
prefixed `(user)` / `(project)`.
