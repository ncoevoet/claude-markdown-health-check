#!/usr/bin/env bash
# Run the deterministic gates (no network / API key needed — safe for CI):
#   1. anonymization gate  — no real scanned-project names in published artifacts
#   2. eval-schema gate    — every evals/*.json matches the case contract
#   3. deterministic suite — scanners emit the right tags for each fixture
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
  bash "$REPO/commands/scripts/validate-evals.sh" || rc=1
  echo
fi

echo "== deterministic scanner tests =="
bash "$HERE/test_scripts.sh" "$filter" || rc=1

echo
if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
