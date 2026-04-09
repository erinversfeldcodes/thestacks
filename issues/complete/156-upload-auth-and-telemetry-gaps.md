# Issue #156: Tests — status endpoint auth guard + isbn_not_found telemetry isolation

## Summary
Two short test gaps: (1) `GET /api/upload/:id/status` has no 401 test verifying the auth guard rejects unauthenticated requests; (2) the telemetry suite covers Oban job cancellation generically but has no isolated assertion for the `isbn_not_found` cancel reason specifically.

## User Stories
US-1.1.1, US-1.1.2

## Goal
Two new tests that close the auth guard and telemetry isolation gaps.

## Scope Check
- All items pass — test-only, ~50 LOC total.

## Wiring
- [x] Implementation only.

## Technical Requirements

### Test 1 — Auth guard: 401 for unauthenticated status poll
File: `apps/core/test/stacks/upload_pipeline_test.exs` (Suite 1 or a new auth describe block)

- Send `GET /api/upload/:id/status` with no Authorization header.
- Assert `json_response(conn, 401)`.
- The endpoint is in the `:authenticated` Guardian pipeline — no production change needed.

### Test 2 — Telemetry: isolated `isbn_not_found` cancel
File: `apps/core/test/stacks/upload_telemetry_test.exs`

- `IdentifyBookJob` returns `{:cancel, "isbn_not_found"}` when `Moderation.run_pipeline/1` returns `{:error, :isbn_not_found}`.
- Attach `[:oban, :job, :stop]` telemetry. Run `perform_job(IdentifyBookJob, ...)` with the `NoIsbnClient` mock.
- Assert the telemetry fires with `metadata.state == :cancelled` (or `:discarded` — check Oban's actual telemetry payload) AND that the cancel reason matches `"isbn_not_found"`.
- The existing `upload_telemetry_test.exs` has a cancellation test for `not_a_book`; mirror that pattern exactly.

## Reviewer Context
- Guardian auth pipeline: `apps/core/lib/stacks_web/router.ex` — upload routes are in the `:authenticated` scope.
- Oban telemetry metadata keys for cancelled jobs: check the existing not_a_book cancellation test in `upload_telemetry_test.exs` for the exact assertion pattern.
- `NoIsbnClient` is already defined in `upload_dbt_test.exs` — check if it's accessible or define a local one.

## Definition of Done
- [ ] Test `"returns 401 when unauthenticated for GET /api/upload/:id/status"` passes
- [ ] Test `"[:oban, :job, :stop] fires with state cancelled for isbn_not_found"` passes
- [ ] `mix test` green, `mix credo --strict` clean

## Dependencies
None.

## Agent Assignment
elixir-agent

## Progress Notes
