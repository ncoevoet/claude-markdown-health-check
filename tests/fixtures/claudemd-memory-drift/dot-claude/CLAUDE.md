# Sample project

A reporting service that exports weekly usage summaries.

## Build

- `make build` — builds the exporter
- `make test` — runs the snapshot suite

## Notes to self

- Remember the staging exporter runs an hour behind production
- The user prefers CSV over XLSX for the weekly export
- Reminder: the snapshot suite needs the fixtures refreshed after a schema change
