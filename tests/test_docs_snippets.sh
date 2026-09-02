#!/usr/bin/env bash
# Regression guard for the executable snippets published in plugin/references/*.md.
#
# These snippets are run by the model, not by a script, so nothing else exercises them.
# The body-compression formula in particular shipped an awk that never left code mode
# (the closing fence set in_code=0 and then fell through to the rule that set it back
# to 1), so every line after the first fence was discarded and the filler ratio was
# computed against a denominator of a handful of words.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

DOC="$REPO/plugin/references/body-compression.md"
FIXTURE="$HERE/fixtures/body-filler/sample.md"

echo "=== docs-snippets: body-compression filler formula ==="

# Extract the first bash block of the doc and run it against the fixture.
snippet=$(awk '/^  ```bash$/{f=1;next} f&&/^  ```$/{exit} f' "$DOC")
if [ -z "$snippet" ]; then
    no "docs-snippets: found a bash snippet in body-compression.md"
else
    ok "docs-snippets: found a bash snippet in body-compression.md"
fi

# The snippet reads $file and sets body_words / pct_code / ratio.
file="$FIXTURE"
if [ -f "$file" ]; then
    ok "docs-snippets: fixture present at ${file#"$REPO"/}"
else
    no "docs-snippets: fixture present at ${file#"$REPO"/}"
    exit 1
fi
body_words=""; pct_code=""; ratio=""
eval "$snippet"

# 7 prose words: "# Heading"(2) + "alpha beta gamma"(3) + "delta epsilon"(2).
# The two `const` lines and the fences must NOT count.
if [ "$body_words" = "7" ]; then
    ok "docs-snippets: body_words == 7 (prose only, code fences excluded)"
else
    no "docs-snippets: body_words == 7 (prose only, code fences excluded) — got $body_words"
fi

# 4 of 11 body lines are fenced (2 fences + 2 code lines) -> 4*100/(11+1) = 33.
if [ "$pct_code" = "33" ]; then
    ok "docs-snippets: pct_code == 33 (fenced-code ratio available for the 70% skip rule)"
else
    no "docs-snippets: pct_code == 33 — got $pct_code"
fi

# No filler words in the fixture, so the ratio must be 0 rather than a division artefact.
if [ "$ratio" = "0" ]; then
    ok "docs-snippets: ratio == 0 on filler-free prose"
else
    no "docs-snippets: ratio == 0 on filler-free prose — got $ratio"
fi

printf '\ndocs-snippets: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
