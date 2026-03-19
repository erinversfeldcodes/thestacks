# Issue #074: EventEnvelope Proto Conformance — schema_version, emit/1 contract comment, buf COMMENTS rule

## Summary

`Stacks.Events.emit/1` writes rows to `op.event_log` but does not set `schema_version`, which is field 4 of the `EventEnvelope` proto contract. The function also has no cross-reference to the proto schema, making it easy for callers to drift from the contract. `buf.yaml` does not enforce the `COMMENTS` lint rule, so proto fields can be added without documentation.

## User Stories

None directly — this is a technical contract-enforcement issue that underpins all event-driven user stories (Phase 1+).

## Goal

- `emit/1` writes `schema_version` to every event row (defaulting to 1, overridable by callers).
- `emit/1` has a module-level or function-level comment that explicitly names `proto/stacks/internal/v1/event_bus.proto` as the canonical schema.
- `buf.yaml` enforces `COMMENTS` so all future proto field additions must be documented.

## Technical Requirements

### 1. Add `schema_version` to `emit/1`

In `apps/core/lib/stacks/events.ex`, the `params` map built inside `emit/1` is missing `schema_version`. Add it:

```elixir
params = %{
  ...
  schema_version: Map.get(event, :schema_version, 1),
  ...
}
```

Callers that need a non-1 schema version (e.g. after a breaking payload change) can pass `schema_version:` explicitly. Default is 1.

The `op.event_log` table already has a `schema_version` column (added in the initial migration alongside `#070`).

### 2. Add proto cross-reference comment to `emit/1`

The existing `@doc` on `emit/1` lists required keys but does not reference the proto. Add a line:

```
See `proto/stacks/internal/v1/event_bus.proto` (`EventEnvelope`) for the canonical field contract.
```

### 3. Enable `COMMENTS` lint rule in `buf.yaml`

`proto/buf.yaml` currently uses the `STANDARD` ruleset. Add `COMMENTS` to the `use` list (it is not included in `STANDARD`):

```yaml
lint:
  use:
    - STANDARD
    - COMMENTS
  enum_zero_value_suffix: _UNSPECIFIED
```

Then run `buf lint` to confirm no existing proto fields violate it — all fields in `event_bus.proto` already have comments so this should be a no-op for existing files.

## Definition of Done

- [ ] `emit/1` params map includes `schema_version: Map.get(event, :schema_version, 1)`
- [ ] Unit test in `events_test.exs` asserts that emitted rows have `schema_version: 1` by default and that passing `schema_version: 2` writes 2
- [ ] `emit/1` `@doc` references `proto/stacks/internal/v1/event_bus.proto`
- [ ] `buf.yaml` includes `COMMENTS` in the lint rule set
- [ ] `buf lint` passes with no errors
- [ ] `mix test apps/core/test/stacks/events_test.exs` passes
- [ ] `mix credo --strict` passes

## Dependencies

- Issue #045 (Elixir contexts + event_log migration) — `op.event_log.schema_version` column must exist
- Issue #070 (event bus) — `emit/1` must be the final Wave A implementation

## Agent Assignment

elixir-agent

## Progress Notes

Scoped 2026-03-19 after Wave A audit. `emit/1` writes to `op.event_log` without `schema_version`, diverging from the `EventEnvelope` proto contract established in #070. The column exists in the DB; only the application-layer write and the buf lint rule are missing.

**2026-03-19 — Complete.** All three original gaps closed plus scope expanded during review: `published_at` proto field (field 8) added and `SubscriberWorker.mark_published/1` implemented; `metadata` NOT NULL migration added; `buf.yaml` hardened with `disallow_comment_ignores: true` and `FILE` breaking detection; `fetch_batch/3` extended to select `published_at`. Two review rounds, all APPROVED. 315 tests, 0 failures. See `plans/074-event-envelope-conformance-complete.md`.
