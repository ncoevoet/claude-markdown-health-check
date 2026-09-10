---
name: renderer
description: Renders invoice PDFs from the template set and compares them against golden files. Use when changing invoice layout, fonts, or the golden-file suite.
---

# Renderer

The renderer walks the template set, fills each field, and writes a PDF next to
the golden file it is compared against.

## Layout changes

- Generated files under `build/` must never be edited by hand
- A layout change usually shifts every golden file; regenerate them in one pass
