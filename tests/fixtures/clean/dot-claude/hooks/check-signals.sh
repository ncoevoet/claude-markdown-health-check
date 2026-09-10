#!/usr/bin/env bash
# Conventional standalone hook — well-formed: shebang present, no eval of input,
# blocks correctly with exit 2 when needed.
set -euo pipefail
payload=$(cat)
if printf '%s' "$payload" | grep -q "forbidden"; then
    echo '{"decision":"block","reason":"forbidden token"}'
    exit 2
fi
exit 0
