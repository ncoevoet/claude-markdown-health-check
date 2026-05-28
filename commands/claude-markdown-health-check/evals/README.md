# Evals for `/claude-markdown-health-check`

Data-driven test cases, following Anthropic's
[develop-tests](https://platform.claude.com/docs/en/test-and-evaluate/develop-tests)
methodology. Each `NN-name.json` describes a fixture `.claude/` tree (under
`tests/fixtures/<dir>/`) and the findings the audit must (and must not) produce.

Two grading tiers (develop-tests: code-grading > LLM-grading):

| `grader.method` | Run by | Cost | What it proves |
|-----------------|--------|------|----------------|
| `code` | `tests/run.sh` (CI) | free, deterministic | the scanners emit exactly the right tag set for a planted defect, and **zero** findings for the clean tree |
| `llm-rubric` | `scripts/run-evals-headless.sh` (opt-in) | tokens | the judgment phases (weak description, thin CLAUDE.md, autonomy gate) behave, graded by an LLM against `grader_rubric` |

## Schema

```jsonc
{
  "id": "02-dead-ref",
  "command": "claude-markdown-health-check",
  "fixture": {
    "kind": "claude-tree",            // fixture is tests/fixtures/<dir>/.claude
    "dir": "tests/fixtures/dead-ref",
    "needs_home_override": false,     // true: copy tree into a temp $HOME/.claude
                                      //       (user-tree-gated scans: plugins, scan-graph memory)
    "scanners": ["validate-skills"]   // validate-skills | scan-graph  (code cases)
  },
  "grader": { "method": "code" },     // code | llm-rubric
  "success_criteria": {               // code cases
    "must_detect": [ { "tag": "DEAD-REF", "path_substring": "brokenskill" } ],
    "must_not_flag": [ "MISSING-DESC" ],   // tags that must be ABSENT (false-positive guard)
    "expect_clean": false             // true: the whole tag set must be empty
  },
  "query": "/claude-markdown-health-check",   // llm-rubric cases
  "grader_rubric": "PASS only if ... last line PASS|FAIL",
  "expected_behavior": [ "..." ],
  "expected_not_behavior": [ "..." ],
  "assert_no_writes": true            // llm-rubric: fixture tree must be byte-identical after the run
}
```

Tags are the stable machine contract: the human report (Phase 24) is just a
friendlier projection over the same tags, so the `code` cases are immune to
report-format changes.

## Running

```bash
make test                              # all code-graded cases (CI)
bash tests/run.sh 02                   # one case / prefix
make evals                             # opt-in LLM-graded cases (needs `claude` CLI)
HEALTH_CHECK_EVAL_RUNS=3 make evals    # majority vote over 3 runs to smooth LLM noise
```

## Growing the suite

Every real-world miss or false positive should become a new case. Add a fixture
tree under `tests/fixtures/<name>/.claude/...`, then a `NN-name.json` here.

**Future work — history phases.** Phases that read session telemetry via
`scan-history.sh` (SKILL-DORMANT, SKILL-NEVER-FIRED, HOOK-FAILING, token trend)
are not yet covered: they need synthetic `~/.claude/projects/*/*.jsonl`
transcripts. The `.jsonl` schema is intricate; build a `synthetic-jsonl` fixture
kind to cover them.
