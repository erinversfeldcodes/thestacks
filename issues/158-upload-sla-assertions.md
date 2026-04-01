# Issue #158: Tests — SLA assertions for upload pipeline endpoints

## Summary
Upload pipeline endpoints have no response-time assertions. Telemetry duration data is captured but never bounded. This issue adds lightweight SLA guards to the key upload endpoints so latency regressions are caught in CI.

## User Stories
US-1.1.1, US-1.1.5

## Goal
Key upload endpoints fail the test suite if they exceed defined SLA thresholds under test conditions (local, no external calls).

## Scope Check
- Test-only. ~40 LOC.

## Wiring
- [x] Implementation only.

## Technical Requirements

File: `apps/core/test/stacks/upload_telemetry_test.exs` or a new `upload_sla_test.exs`

Endpoints and thresholds (generous for CI; goal is regression detection, not production SLAs):
- `POST /api/upload` — accept image bytes → 202 — assert < 500ms
- `GET /api/upload/:id/status` — poll for status → 200 — assert < 100ms
- `POST /api/upload/identify` — manual ISBN lookup → 200/422 — assert < 200ms

Pattern:
```elixir
{elapsed_us, _conn} = :timer.tc(fn ->
  conn |> auth_conn(token) |> post("/api/upload", ...)
end)
assert elapsed_us < 500_000, "POST /api/upload exceeded 500ms SLA: #{elapsed_us}μs"
```

## Reviewer Context
- These thresholds should be generous (5–10× expected production response time) so they only fail on genuine regressions, not normal CI variance.
- `POST /api/upload` stores to local filesystem in test (`TEST_TARGET=offline`) so storage latency is negligible.
- Mark tests with `@tag :sla` so they can be excluded in slow environments: `mix test --exclude sla`.

## Definition of Done
- [ ] SLA tests for POST /api/upload, GET /api/upload/:id/status, POST /api/upload/identify
- [ ] Thresholds are documented inline with rationale
- [ ] Tests tagged `@tag :sla` and excluded by default in `test/test_helper.exs` if ExUnit supports it
- [ ] `mix test` green (including SLA tests)

## Dependencies
None.

## Agent Assignment
elixir-agent

## Progress Notes
