# Sample project

A small service that renders invoices as PDFs.

## Build

- `make build` — compiles the renderer
- `make test` — runs the golden-file suite

## Conventions

- Generated files under `build/` must never be edited by hand
- Fonts are loaded once at startup; adding one requires a restart
