# Completion: EventEnvelope Proto Conformance
**Issue**: #074
**Completed**: 2026-03-19
**Agent(s)**: elixir-agent (Elixir + buf.yaml)

## Summary

Three conformance gaps between `Stacks.Events.emit/1` and the `EventEnvelope` proto contract were closed, the `COMMENTS` buf lint rule was enabled and hardened, and `SubscriberWorker` was extended to write a delivery audit timestamp. Scope grew during review from the original three-gap fix into a fuller event-bus conformance pass covering schema, delivery auditability, and buf governance.

## Files Created

- `apps/core/priv/repo/migrations/20260319000001_fix_event_log_metadata_not_null.exs` — backfills NULL `metadata` rows; adds `NOT NULL DEFAULT '{}'::jsonb`

## Files Modified

- `apps/core/lib/stacks/events.ex`
  - `emit/1` params map: added `schema_version: Map.get(event, :schema_version, 1)`
  - `emit/1` `@doc`: added `:schema_version` option and proto cross-reference
  - `emit/1` `@spec`: replaced `map()` with precise typed map spec (required/optional keys)
  - `fetch_batch/3` select: added `published_at: e.published_at`
- `apps/core/test/stacks/events_test.exs`
  - `import Ecto.Query` lifted to module level
  - Added `describe "emit/1 schema_version"` with two DB-querying tests
- `apps/core/lib/stacks/events/subscriber_worker.ex`
  - Added `mark_published/1` — writes `published_at = DateTime.utc_now()` after dispatch
  - `perform/1` calls `mark_published(event.id)` after `dispatch/1` returns
- `apps/core/test/stacks/events/subscriber_worker_test.exs`
  - `import Ecto.Query` lifted to module level
  - Added test: asserts `published_at` is null before dispatch, non-null after
- `proto/stacks/internal/v1/event_bus.proto`
  - Field 8: `optional google.protobuf.Timestamp published_at` (delivery audit timestamp)
- `proto/stacks/common/v1/book.proto`
  - 13 enum value leading comments added across `ISBNFormat`, `EditionFormat`, `VisibilityTier` (required side-effect of enabling `COMMENTS` rule)
- `proto/buf.yaml`
  - `lint.use`: added `- COMMENTS`
  - `lint.disallow_comment_ignores: true` — prevents `buf:lint:ignore` suppression of COMMENTS
  - `breaking.use`: `[WIRE]` → `[FILE]` — catches source-level renames in addition to wire breaks

## Test Results

- Elixir: 315 tests, 0 failures
- `buf lint proto/`: clean (exit 0)
- `mix credo --strict`: 525 mods/funs, no issues

## Review Rounds

- **Round 1** (elixir-reviewer, contract-reviewer, protobuf-reviewer): APPROVED — surfaced `import Ecto.Query` placement, `metadata` nullability, `published_at` proto gap, Dialyzer spec improvement, `disallow_comment_ignores`, `FILE` breaking rule
- **Round 2** (all three reviewers): APPROVED — confirmed `mark_published/1` semantics, `fetch_batch/3` gap closed, proto comment wording fixed ("Absent" not "Null")

## Retrospective

**What went well:**
- Test-first discipline caught the real bug (NOT NULL violation on `schema_version`) before any implementation
- Reviewer-surfaced gaps (`published_at`, `FILE` breaking, `disallow_comment_ignores`) materially improved the outcome beyond the original three-point scope
- `buf COMMENTS` + `disallow_comment_ignores: true` closes a governance gap that would have silently allowed undocumented proto fields in future PRs

**What grew in scope (and why it was right to do it):**
- `published_at` proto field + `mark_published/1`: the DB column existed but was never written or declared in the contract; closing this now avoids a "dark" audit field that could never be trusted
- `metadata NOT NULL` migration: the column was nullable in the DB but the application always wrote `%{}`; the schema now reflects the invariant
- `FILE` over `WIRE` breaking detection: correct for a project that generates code in Elixir, Python, and Rust from proto definitions — wire-safe renames are still source-breaking for those consumers

**Forward notes:**
- `SubscriberWorker` now writes `published_at`; the next step is surfacing delivery-lag metrics (e.g. `published_at - occurred_at`) in telemetry or a dbt mart
- `fetch_event/1` deliberately does not select `published_at` (the field is always null at fetch time — before dispatch); this is intentional and documented
- `emit/1` does not write `published_at` (it is a write-side field set by the worker, not the emitter)
