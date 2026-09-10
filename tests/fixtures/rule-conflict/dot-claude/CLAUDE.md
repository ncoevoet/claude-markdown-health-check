# Sample project

A parser library that turns log lines into structured events.

## Build

- `make build` — builds the parser
- `make test` — runs the corpus tests

## Code style

- Never add comments — code must be self-documenting; extract a named function instead
- Field names follow the wire format, not the Go convention, so the mapping stays greppable
