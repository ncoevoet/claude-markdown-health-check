# Context Coherence

Loaded by `/claude-markdown-health-check` Phase 27. Everything the model reads before
the user's prompt — CLAUDE.md and its imports, skills, commands, rules, output styles —
arrives as one assembled document. The other phases audit each file on its own; this one
judges the assembly.

Source of the rubric: [The new rules of context engineering for Claude 5 generation
models](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models).
Three of its findings drive the tags below — constraints that once bought safety now
cost quality, repetition is no longer needed to make an instruction stick, and
conflicting directives make the model arbitrate before it can start work.

## Relayed from Phase 5 (deterministic — do not re-check)

| Tag | Condition | Tier |
|---|---|---|
| `OVER-CONSTRAINED` | ≥12 ALL-CAPS absolutes (`NEVER`, `ALWAYS`, `MUST`, `MUST NOT`, `DO NOT`, `DON'T`, `MANDATORY`, `STRICTLY FORBIDDEN`, `ABSOLUTE`) per 100 body lines, with ≥8 hits over ≥40 lines. Counted outside frontmatter and fenced code, on SKILL.md / command files / CLAUDE.md / CLAUDE.local.md and every `@import` | Hygiene |
| `INSTRUCTION-DUPLICATED` | one normalized directive line (≥40 chars, carrying must/never/always/required/forbidden) present verbatim in ≥2 context files | Hygiene |

Calibration for `OVER-CONSTRAINED`: ordinary skills measure 0–8 absolutes per 100 body
lines; a file written in the "ABSOLUTE RULE" register measures 18–20. The threshold sits
between them, so a handful of hard rules never trips it.

Remediation to propose:
- `OVER-CONSTRAINED` — keep the absolutes that guard something irreversible (data loss,
  secrets, publishing) and rewrite the rest as description. "Match the surrounding
  code's comment density" carries the same intent as "NEVER write comments" without
  making the model choose between the rule and the situation.
- `INSTRUCTION-DUPLICATED` — keep one copy, in the file that owns the topic (the skill
  for skill-specific rules, CLAUDE.md for repo-wide ones), and delete the other. Two
  copies drift: one gets updated, the other silently contradicts it.

## Judgment check — `RULE-CONFLICT` (Structural)

Two directives in scope that a single request cannot satisfy at once. Real examples:

- CLAUDE.md says "never add comments"; a skill says "document every exported function".
- An output style demands terse answers; a skill demands a worked example every time.
- A rule file forbids new files; a skill's workflow writes a spec file as step 1.

KEEP only with **both sides quoted**, each with its file and line, plus one sentence
naming the request that would be answered differently depending on which directive wins.
The Pre-print grounding gate (`finding-verification.md`) enforces this.

Not conflicts — abstain rather than guess:
- Different topics that merely share vocabulary.
- Emphasis differences: "prefer X" against "X unless Y" is a refinement, not a clash.
- A general rule and its documented exception, when the exception names its condition.
- Scope-separated directives: a project rule overriding a user-level default is the
  documented precedence, not a contradiction.

One finding per conflicting pair, in the scope of the file that should change.
