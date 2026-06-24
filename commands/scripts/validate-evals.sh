#!/usr/bin/env bash
# validate-evals.sh — schema/validity gate for claude-markdown-health-check eval
# cases. Validates every evals/*.json (skipping README*) against the contract the
# headless runner (run-evals-headless.sh) and the deterministic suite depend on,
# so a malformed case is caught cheaply HERE instead of wasting an expensive
# `claude -p` eval run (or a confusing test failure) on it.
#
# Per case (ERROR = fails the gate):
#   - parses as a JSON object
#   - id == filename stem
#   - .command == "claude-markdown-health-check"
#   - fixture.kind == "claude-tree"
#   - fixture.dir is non-empty, exists on disk, and has a .claude/ subtree
#   - fixture.scanners ⊆ { "validate-skills", "scan-graph" }
#   - grader.method ∈ { "code", "llm-rubric" }
#   - code      cases: success_criteria is an object; must_detect (if present) is an array
#   - llm-rubric cases: non-empty grader_rubric OR non-empty expected_behavior
#
# WARN (informational, does not fail): llm-rubric case without a boolean
# assert_no_writes (the autonomy-gate harness expects it).
#
# Exit 0 if all valid, 1 if any ERROR, 2 on bad usage.
# Usage: validate-evals.sh [EVALS_DIR]   (defaults to the repo's evals dir)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"          # commands/scripts
REPO="$(cd "$HERE/../.." && pwd)"
EVALS="${1:-$REPO/commands/claude-markdown-health-check/evals}"

command -v jq >/dev/null 2>&1 || { echo "validate-evals: jq is required." >&2; exit 2; }
[ -d "$EVALS" ] || { echo "validate-evals: no such dir: $EVALS" >&2; exit 2; }

errors=0
warns=0
ncases=0

err()  { echo "ERROR $1"; errors=$((errors + 1)); }
warn() { echo "WARN  $1"; warns=$((warns + 1)); }

for f in "$EVALS"/*.json; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in README*|readme*) continue ;; esac
  ncases=$((ncases + 1))
  stem="${base%.json}"

  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    err "$base: not a valid JSON object"
    continue
  fi

  [ "$(jq -r '.id // empty' "$f")" = "$stem" ] \
    || err "$base: id ('$(jq -r '.id // empty' "$f")') != filename stem ('$stem')"

  [ "$(jq -r '.command // empty' "$f")" = "claude-markdown-health-check" ] \
    || err "$base: .command != 'claude-markdown-health-check'"

  fkind="$(jq -r '.fixture.kind // empty' "$f")"
  case "$fkind" in
    claude-tree|synthetic-jsonl) ;;
    *) err "$base: fixture.kind '$fkind' not in { claude-tree, synthetic-jsonl }" ;;
  esac

  dir="$(jq -r '.fixture.dir // empty' "$f")"
  if [ -z "$dir" ]; then
    err "$base: fixture.dir missing/empty"
  elif [ ! -d "$REPO/$dir" ]; then
    err "$base: fixture.dir '$dir' does not exist on disk"
  elif [ ! -d "$REPO/$dir/.claude" ]; then
    err "$base: fixture.dir '$dir' has no .claude/ subtree"
  fi

  badscan="$(jq -r '(.fixture.scanners // [])
                     | map(select(. != "validate-skills" and . != "scan-graph" and . != "scan-history"))
                     | join(",")' "$f")"
  [ -z "$badscan" ] || err "$base: fixture.scanners has unknown entries: $badscan"

  method="$(jq -r '.grader.method // empty' "$f")"
  case "$method" in
    code)
      if [ "$fkind" = "synthetic-jsonl" ]; then
        jq -e '(.success_criteria.history_assertions | type == "array" and length > 0)
               and all(.success_criteria.history_assertions[]?; has("jq"))' \
           "$f" >/dev/null 2>&1 \
          || err "$base: synthetic-jsonl code case needs a non-empty success_criteria.history_assertions[] (each with a .jq path)"
      else
        jq -e '(.success_criteria | type == "object")
               and ((.success_criteria | has("must_detect") | not)
                    or (.success_criteria.must_detect | type == "array"))' \
           "$f" >/dev/null 2>&1 \
          || err "$base: code case needs success_criteria object with array must_detect (if present)"
      fi
      ;;
    llm-rubric)
      jq -e '((.grader_rubric // "")     | type == "string" and length > 0)
             or ((.expected_behavior // []) | type == "array" and length > 0)' \
         "$f" >/dev/null 2>&1 \
        || err "$base: llm-rubric case needs non-empty grader_rubric or expected_behavior"
      jq -e '.assert_no_writes | type == "boolean"' "$f" >/dev/null 2>&1 \
        || warn "$base: llm-rubric case has no boolean assert_no_writes"
      ;;
    "")
      err "$base: missing grader.method" ;;
    *)
      err "$base: grader.method '$method' not in { code, llm-rubric }" ;;
  esac
done

[ "$ncases" -gt 0 ] || { echo "validate-evals: no eval cases found in $EVALS" >&2; exit 2; }

if [ "$errors" -gt 0 ]; then
  echo "validate-evals: $errors error(s) across $ncases case(s)" >&2
  exit 1
fi
tail=""
[ "$warns" -gt 0 ] && tail=", $warns warning(s)"
echo "validate-evals: $ncases case(s) valid$tail"
exit 0
