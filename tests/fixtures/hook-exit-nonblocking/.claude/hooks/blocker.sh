#!/usr/bin/env bash
set -euo pipefail
payload=$(cat)
if printf '%s' "$payload" | grep -q "rm -rf"; then
    echo '{"decision":"block","reason":"destructive command"}'
    exit 1
fi
exit 0
