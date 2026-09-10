# Sample project

A queue consumer that turns webhook payloads into billing events.

## Build

- `make build` — builds the consumer
- `make test` — runs the replay suite against recorded payloads

## Architecture

- `consumer/` — one goroutine per partition; ordering is per-tenant, not global
- `mapping/` — payload → event translation; the only place vendor quirks live
- `replay/` — reads recorded payloads; used by the test suite and by support
- `store/` — idempotency keys; a duplicate delivery must resolve to the same event
- `cmd/` — entry points; the daemon and the one-shot replay share flags here
- `internal/clock/` — injectable clock, because billing windows are wall-clock bound

## Gotchas

- A payload without a tenant header is routed to partition 0, which serializes
  every unattributable event — check this first when throughput drops.
- The vendor retries with the same delivery id but a new timestamp, so
  idempotency keys must never include the timestamp.

## Notes

- Remember the sandbox vendor account rotates its signing key every Monday
- The user prefers replay output as NDJSON
