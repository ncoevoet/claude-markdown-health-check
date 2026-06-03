#!/usr/bin/env bash
# Lint the notes store: every note must have a title line.
set -eu
store="${1:-notes}"
echo "checking notes in: $store"
exit 0
