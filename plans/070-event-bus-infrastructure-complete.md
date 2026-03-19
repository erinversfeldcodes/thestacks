# Plan: Event Bus Infrastructure Completion — Complete
**Issue**: #070
**Created**: 2026-03-19
**Status**: Complete

---

## Context

Issue #070 completed the EDA infrastructure in `Stacks.Events`: the `Registry` (compile-time subscriber map), `SubscriberWorker` (Oban fan-out dispatcher), `Upcaster` (schema version transforms), `replay/3` (historical backfill), and the `Handler` behaviour. This completes Phase 1B.1 of the consolidated roadmap and unblocks all event-driven contexts.

---

## Research Summary

Pre-existing state: `Stacks.Events` had only `emit/1` and `emit_safe/1`. No subscriber dispatch existed. The `event_log` table (Issue #043) and Oban infrastructure were already in place.

---

## Implementation Summary

### Files Created

- `apps/core/lib/stacks/events/handler.ex` — `Stacks.Events.Handler` behaviour with `@callback handle_event/1`
- `apps/core/lib/stacks/events/registry.ex` — Compile-time `@registry` map; `handlers_for/1`, `all_event_types/0`
- `apps/core/lib/stacks/events/upcaster.ex` — `upcast/1` with v1 passthrough and catch-all
- `apps/core/lib/stacks/events/subscriber_worker.ex` — Oban worker (queue: :events, max_attempts: 3); fetches event by ID, dispatches per-handler with try/rescue isolation, telemetry on failure
- `apps/core/test/stacks/events/registry_test.exs` — Registry unit tests
- `apps/core/test/stacks/events/upcaster_test.exs` — Upcaster unit tests
- `apps/core/test/stacks/events/subscriber_worker_test.exs` — SubscriberWorker unit tests + telemetry test

### Files Modified

- `apps/core/lib/stacks/events.ex` — `emit/1` now enqueues `SubscriberWorker`; `replay/3` added (batched at 500)
- `apps/core/test/stacks/events_test.exs` — `assert_enqueued` test for emit; `replay/3` tests

---

## Approach Options

- **Option A (chosen): Compile-time Registry + single fan-out Oban worker** — Central `@registry` module attribute, one `SubscriberWorker` job per event that dispatches to all handlers. Simple, zero runtime state, correct for Phase 1 scale. Recommended.
- **Option B: ETS-backed runtime registry** — Allows dynamic handler registration without deploy. Adds runtime state and test isolation complexity. Not needed for Phase 1.
- **Option C: One Oban job per handler** — Enables per-handler retry and dead-letter separation. Requires Oban Pro or custom job-per-handler logic. Overkill for Phase 1; revisit if observability requirements grow.

---

## Phases

### Phase 1: Event Bus Infrastructure (single phase)
**Objective**: Implement Registry, SubscriberWorker, Upcaster, Handler behaviour, replay/3, and updated emit/1.
**Agent(s)**: elixir-agent (Opus)
**Reviewer**: elixir-reviewer
**Test Command**: `mix test`
**DoD Items**: All satisfied — see DoD Verification below.

---

## Regression Gate Results

- `mix test`: **312 tests, 0 failures**
- `mix credo --strict`: **clean** (524 mods/funs, no issues)
- `mix format --check-formatted`: **clean**
- `mix compile --warnings-as-errors`: **clean**
- `mix sobelow --config`: **no high-severity findings**

---

## Review Summary

**Verdict: APPROVED** (after one targeted revision)

**Reviewer finding (resolved):** The Technical Requirements specified "increment a telemetry counter" for failed handler calls. The initial implementation omitted `:telemetry.execute/3`. Fixed by adding telemetry emission in both the `{:error, reason}` and `rescue` branches of `SubscriberWorker.dispatch/2`, plus a corresponding telemetry test. Re-verified: 312 tests pass.

**Non-blocking notes from review:**
- SubscriberWorker has no unique constraint on args — relies on handler idempotency for at-least-once delivery (acceptable for Phase 1)
- SubscriberWorker dispatch tests cover the no-handler case only; a future revision could add a mock-handler test for full dispatch path coverage
- Registry tests verify empty-registry behaviour only (correct for current state)

---

## PE Gate Assessment

**Overall Health: GREEN**

ADR-002 (Oban over Kafka) is fully respected:
- `emit/1` writes to `op.event_log` then enqueues Oban job (not stored in job args)
- No external broker introduced
- Retry via Oban exponential backoff (max_attempts: 3)
- `replay/3` queries `event_log` directly — correct for backfill semantics
- `:events` queue at concurrency 20 is additive to ADR queue table, not a deviation

No P0 issues. No architectural concerns.

---

## DoD Verification

- [x] `Events.Registry` module with `handlers_for/1` and `all_event_types/0` — `registry.ex:30,40`
- [x] `Events.SubscriberWorker` Oban worker dispatches to registered handlers — `subscriber_worker.ex:25-35`
- [x] Failed individual handler calls logged but non-fatal — `subscriber_worker.ex:65-91` (per-handler try/rescue + telemetry)
- [x] `Events.Upcaster` with `upcast/1` and at least one documented no-op clause (v1 → v1) — `upcaster.ex:26-27`
- [x] `Events.replay/3` replays historical events with upcasting, batched at 500 — `events.ex:128`, `@replay_batch_size 500`
- [x] `emit/1` enqueues `SubscriberWorker` after writing to `event_log` — `events.ex:51-53`
- [x] `Stacks.Events.Handler` behaviour defined — `handler.ex:23`
- [x] Unit tests: Registry lookup, SubscriberWorker dispatch, Upcaster passthrough — all present and passing
- [x] `mix test` passes — 312 tests, 0 failures
- [x] `mix credo --strict` passes — clean

---

## Forward Compatibility

- **Issue #050** (Price + Review Enrichment): Can subscribe to `book.created` via `Registry` and implement `@behaviour Stacks.Events.Handler`. API is stable — READY.
- **Issue #073** (Email Confirmation Gate): Can define `Stacks.Notifications.EmailHandler @behaviour Stacks.Events.Handler`. API is stable — READY.

---

## Open Questions

None.

---

## Integration Handoffs

Issue #070 → Issue #050: `Registry.handlers_for/1` returns handler modules; `Handler` behaviour defines `handle_event/1`. No changes needed to these interfaces before Issue #050 work begins.

Issue #070 → Issue #073: `Handler` behaviour (`handle_event/1` returning `:ok | {:error, term()}`) is the only contract. Stable.
