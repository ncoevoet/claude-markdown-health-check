#!/usr/bin/env bash
# Run the deterministic gates (no network / API key needed — safe for CI):
#   1. anonymization gate  — no real scanned-project names in published artifacts
#   2. eval-schema gate    — every evals/*.json matches the case contract
#   3. deterministic suite — scanners emit the right tags for each fixture
#   4. history aggregation — scan-history.sh aggregates synthetic transcripts
#   5. docs snippets      — executable snippets in plugin/references/*.md still compute correctly
#   6. tag registration   — every tag the scripts can emit is registered in the command file and references
# Usage:
#   bash tests/run.sh           # full gate set (CI)
#   bash tests/run.sh <prefix>  # only the deterministic suite, one case/prefix (dev)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
rc=0
filter="${1:-}"

if [ -z "$filter" ]; then
  echo "== anonymization gate =="
  bash "$HERE/check-anonymization.sh" || rc=1
  echo
  echo "== eval-schema gate =="
  bash "$REPO/plugin/commands/scripts/validate-evals.sh" || rc=1
  echo
fi

echo "== deterministic scanner tests =="
bash "$HERE/test_scripts.sh" "$filter" || rc=1

echo
echo "== history aggregation tests =="
bash "$HERE/test_history.sh" "$filter" || rc=1

if [ -z "$filter" ]; then
  echo
  echo "== docs snippet tests =="
  bash "$HERE/test_docs_snippets.sh" || rc=1
  echo
  echo "== tag registration gate =="
  bash "$HERE/check-tag-registration.sh" || rc=1
fi

echo
if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
