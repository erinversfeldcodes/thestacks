# Plan: EventEnvelope Proto Conformance — schema_version, emit/1 comment, buf COMMENTS rule
**Issue**: #074
**Created**: 2026-03-19
**Status**: Draft

## Context

`Stacks.Events.emit/1` writes events to `op.event_log` but omits `schema_version` from the insert params, diverging from the `EventEnvelope` proto contract (field 4). The column already exists in the DB with `default: 1` and both read paths (`fetch_batch/3`, `SubscriberWorker.fetch_event/1`) already select it. This is a Wave A audit item: three lines of change, no migration, no risk.

## Research Summary

- **Gap 1:** `emit/1` params map (events.ex ~line 47) omits `schema_version`; all existing DB rows have implicit `default: 1` but the application never writes it explicitly.
- **Gap 2:** `emit/1` `@doc` does not reference `proto/stacks/internal/v1/event_bus.proto`.
- **Gap 3:** `proto/buf.yaml` uses `STANDARD` ruleset only; `COMMENTS` must be added explicitly. All existing proto fields already have comments so `buf lint` will be clean after the addition.
- **No risk:** DB column exists (`null: false, default: 1`). Upcaster already patterns on `schema_version`. Readers already select it. Adding the write is purely additive.

## Approach Options

- **Option A (chosen): Single phase, one commit.** All three changes are independent and have no interaction risk. Shipping them together keeps the commit small and self-contained. Recommended.
- **Option B: Two phases (Elixir then proto lint).** No justification for the split — the proto change is one line and requires no coordination with the Elixir phase.
- **Option C: Three separate commits.** Creates noisy history for trivial, atomically-safe changes. Not recommended.

## Phases

### Phase 1: EventEnvelope Conformance (single phase)
**Objective**: Make `emit/1` write `schema_version`, add proto cross-reference to its `@doc`, add two test cases covering default and override, and enable `COMMENTS` lint in `buf.yaml`.
**Agent(s)**: elixir-agent (owns Elixir + the buf.yaml one-liner)
**Steps**:
1. In `emit/1` params map, add `schema_version: Map.get(event, :schema_version, 1)`
2. In `emit/1` `@doc`, add: "See `proto/stacks/internal/v1/event_bus.proto` (`EventEnvelope`) for the canonical field contract."
3. In `events_test.exs`, add two assertions: default `schema_version` is 1; passing `schema_version: 2` writes 2.
4. In `proto/buf.yaml`, add `- COMMENTS` under `lint.use`.
5. Run `buf lint proto/` and confirm zero errors.
6. Run `mix test apps/core/test/stacks/events_test.exs` and confirm all pass.
7. Run `mix credo --strict apps/core/` and confirm zero warnings.

**Test Command**: `mix test apps/core/test/stacks/events_test.exs`
**DoD Items**:
- [ ] `emit/1` params map includes `schema_version: Map.get(event, :schema_version, 1)`
- [ ] Unit test: emitted event has `schema_version: 1` by default
- [ ] Unit test: passing `schema_version: 2` writes 2
- [ ] `emit/1` `@doc` references `proto/stacks/internal/v1/event_bus.proto`
- [ ] `buf.yaml` includes `COMMENTS` in the lint rule set
- [ ] `buf lint` passes with no errors
- [ ] `mix test apps/core/test/stacks/events_test.exs` passes
- [ ] `mix credo --strict` passes

**E2E gate**: Skipped — no user-facing behaviour changed. Backend-only conformance fix.

## Open Questions

None. Research confirmed all three changes are safe and independent.

## Integration Handoffs

None — single-phase, single-agent, no cross-phase coordination required.
