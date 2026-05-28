#!/usr/bin/env bash
# Run the deterministic test suite (no network / API key needed — safe for CI).
# Usage: bash tests/run.sh [case-id-prefix]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0

echo "== deterministic scanner tests =="
bash "$HERE/test_scripts.sh" "${1:-}" || rc=1

echo
if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
