# Issue #070: Event Bus Infrastructure Completion

## Summary
`Stacks.Events` currently provides only `emit/1` and `emit_safe/1`. The consolidated roadmap (Phase 1B.1) requires the remaining EDA infrastructure: `Events.Registry` (subscriber mapping), `Events.SubscriberWorker` (Oban dispatcher), `Events.Upcaster` (version transforms), and `Events.replay/3`. Without this, no context can consume events emitted by other contexts.

## User Stories
US-0.X (platform infrastructure — enables all EDA-dependent user stories)

## Goal
Complete the event bus so that any context can register interest in event types and receive dispatched calls when those events are emitted. `emit/1` writes to `event_log`; `SubscriberWorker` reads from `event_log` and calls each registered handler. Upcaster allows event schema evolution without breaking existing handlers.

## Technical Requirements

**`Stacks.Events.Registry` (new module):**
- Central map: `event_type (string) → [handler_module]` (e.g., `"user.registered" → [Stacks.Notifications.EmailHandler, Stacks.Analytics.UserMetrics]`)
- Defined as a plain module with a compile-time `@registry` attribute (not a GenServer — no runtime state needed)
- `Registry.handlers_for(event_type)` — returns list of handler modules (empty list if unregistered)
- `Registry.all_event_types()` — returns all registered event type strings (for documentation and replay tooling)

**`Stacks.Events.SubscriberWorker` (new Oban worker):**
- Triggered by `emit/1` after writing to `event_log` (emit enqueues a SubscriberWorker job)
- Calls `Registry.handlers_for(event.type)`, invokes `handler.handle_event(event)` for each
- Each handler call wrapped in its own try/rescue — one failing handler must not block others
- Failed handler calls: log error + increment a telemetry counter; do NOT re-raise (event_log entry remains)
- Job args: `%{event_id: uuid}` — worker fetches event from event_log, not stored in job args (avoids PII in Oban queue)

**`Stacks.Events.Upcaster` (new module):**
- `upcast(event)` — given an event map with a `version` field, transforms it to the current version
- Pattern match on `%{type: t, version: v}` — explicit clause per migration needed
- Unknown version: return event unchanged (forward compatibility)
- Document each upcast clause with the migration reason

**`Stacks.Events.replay/3` (new function in `Stacks.Events`):**
- `replay(event_type, from_datetime, handler_module)` — re-dispatches historical events from `event_log` to a single handler
- Used for: backfilling new handlers, recovering from handler failures, audit replay
- Applies `Upcaster.upcast/1` before dispatching
- Batched: processes 500 events at a time (prevent memory blowout on large logs)
- Returns `{:ok, count}` on success

**`emit/1` update:**
- After writing to `event_log`, enqueue `SubscriberWorker` job via `Oban.insert/1`
- Must remain safe: if Oban enqueue fails, log warning but do not raise (event is already persisted)

**Handler behaviour:**
- Define `Stacks.Events.Handler` behaviour with `@callback handle_event(event :: map()) :: :ok | {:error, term()}`
- All handler modules must `@behaviour Stacks.Events.Handler`

## Definition of Done
- [ ] `Events.Registry` module with `handlers_for/1` and `all_event_types/1`
- [ ] `Events.SubscriberWorker` Oban worker dispatches to registered handlers
- [ ] Failed individual handler calls logged but non-fatal
- [ ] `Events.Upcaster` with `upcast/1` and at least one documented no-op clause (version 1 → 1)
- [ ] `Events.replay/3` replays historical events with upcasting, batched at 500
- [ ] `emit/1` enqueues `SubscriberWorker` after writing to `event_log`
- [ ] `Stacks.Events.Handler` behaviour defined
- [ ] Unit tests: Registry lookup, SubscriberWorker dispatch (mock handlers), Upcaster passthrough
- [ ] `mix test` passes
- [ ] `mix credo --strict` passes

## Dependencies
Issue #043 (event_log table must exist)

## Agent Assignment
elixir-agent (Opus — EDA architecture, Oban worker patterns)

## Progress Notes
<!-- Updated by agents during execution -->
Created 2026-03-19 as GAP-03 from roadmap gap analysis. P0 — blocks all event-driven behaviour across all contexts.

2026-03-19 — COMPLETE. Implemented by elixir-agent (Opus). All DoD items satisfied. One reviewer-identified gap (missing telemetry counter on handler failure) resolved during post-implementation review — `:telemetry.execute([:stacks, :events, :handler_error], ...)` added to both error branches of `SubscriberWorker.dispatch/2` with corresponding test. Final: 312 tests, 0 failures, credo clean, sobelow no high-severity findings. Forward compatibility confirmed for Issue #050 (enrichment) and Issue #073 (email confirmation). PE gate: GREEN. Plan: `plans/070-event-bus-infrastructure-complete.md`.
