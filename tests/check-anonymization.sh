#!/usr/bin/env bash
# check-anonymization.sh — release gate: the published artifacts (commands/,
# tests/fixtures/, README.md) must contain NO real employer / product / repo /
# ticket / scanned-project names. This auditor is dogfooded against real
# ~/.claude trees, so an accidental paste of a real finding into an eval fixture
# or a reference doc would leak a name. This repo is PUBLIC, so the REAL blocklist
# lives in a gitignored sibling (anonymization-blocklist.txt) and is never
# committed. When that file is absent (e.g. on CI) the script falls back to the
# committed placeholder example, whose invented patterns never match real content
# — so the mechanism is exercised everywhere while real enforcement happens
# locally pre-commit.
#
# Blocklist format: one extended-regex per line; blank lines and #-comments
# ignored. Exit 0 = clean, 1 = a blocked name was found, 2 = misconfig.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"          # tests/
ROOT="$(cd "$HERE/.." && pwd)"
real="$HERE/anonymization-blocklist.txt"
example="$HERE/anonymization-blocklist.example.txt"

if [[ -f "$real" ]]; then
  list="$real"; mode="real blocklist"
elif [[ -f "$example" ]]; then
  list="$example"; mode="placeholder example (no real blocklist present)"
else
  echo "check-anonymization: no blocklist file found under $HERE" >&2
  exit 2
fi

pattern="$(grep -vE '^[[:space:]]*(#|$)' "$list" | paste -sd '|' -)"
if [[ -z "$pattern" ]]; then
  echo "check-anonymization: blocklist '$list' has no patterns" >&2
  exit 2
fi

echo "check-anonymization: scanning commands/ + tests/fixtures/ + README.md against $mode"
# Scan only published artifacts. The blocklist files live directly under tests/
# (not tests/fixtures/), so they are never scanned and the gate can never match
# its own pattern list.
matches="$(grep -rinE "$pattern" \
  "$ROOT/commands" "$ROOT/tests/fixtures" "$ROOT/README.md" 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 ]]; then
  printf '%s\n' "$matches"
  echo "check-anonymization: FAIL — blocked name(s) above. Anonymize before commit." >&2
  exit 1
elif [[ $rc -eq 1 ]]; then
  echo "check-anonymization: CLEAN"
  exit 0
else
  echo "check-anonymization: grep error (rc=$rc)" >&2
  exit 2
fi
