#!/usr/bin/env bash
# Regression guard: commented-out dangerous patterns must NOT be flagged.
#   eval "$untrusted"                          -> must not trip HOOK-UNSAFE-SHELL
#   echo '{"decision":"block"}'; exit 1        -> must not trip HOOK-EXIT-NONBLOCKING
set -euo pipefail
exit 0
