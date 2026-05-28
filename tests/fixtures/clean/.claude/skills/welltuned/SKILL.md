---
name: welltuned
description: Lints and formats TypeScript files on demand. Use when the user asks to lint, format, or check style in .ts or .tsx files, or mentions eslint or prettier.
allowed-tools: Read, Edit, Bash(eslint:*)
disallowed-tools: WebFetch
model: sonnet
disable-model-invocation: true
effort: low
---

# Welltuned

Run the project linter and report style violations.

## When to use

Use when style or formatting of TypeScript sources needs checking.

## Steps

1. Detect the configured linter.
2. Run it over the changed files.
3. Summarise violations grouped by rule.
