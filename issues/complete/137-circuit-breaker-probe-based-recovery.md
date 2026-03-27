# Issue #137: Circuit Breakers — Probe-Based Half-Open Recovery

## Summary

The current circuit breakers use a purely time-based reset: a blown fuse reopens after
a fixed timer (5–15 min) regardless of whether the underlying service has recovered.
This means a service that recovers in 90 seconds still blocks traffic for the remaining
3.5 minutes, and a service that is still down when the timer fires wastes one real request
before re-blowing. This issue implements probe-based half-open recovery: when a fuse blows,
`Stacks.CircuitBreakers` actively probes the service on a short interval and resets the
circuit as soon as the service responds, rather than waiting out the full timer.

## User Stories

- US-1.1.1 (upload pipeline resilience — vision service recovery should not require
  waiting 5 minutes after Modal comes back up)
- US-2.2.1 (prices — scraper circuit should close the moment the scraper service recovers)
- Underpins all external service reliability and operational maturity

## Goal

When a circuit is blown:
1. `Stacks.CircuitBreakers` probes the affected service every 15 seconds
2. The moment a probe succeeds, it calls `:fuse.reset(name)` to close the circuit immediately
3. If the service never recovers, the existing `{:reset, Ms}` timer fires as a backstop —
   no change to worst-case behaviour
4. A smoke test verifies the full lifecycle: blow all 5 fuses via real failure paths →
   confirm blown → restore probe target → confirm each circuit closes within one probe cycle

## Scope Check

- Does this issue touch more than 3 controllers? No.
- Does this issue add more than 2 new endpoints? Yes — one internal smoke endpoint. Within scope.
- Does this issue exceed ~300 lines of production code? Close — if it does, split the smoke
  endpoint into a follow-on.
- Does this issue combine unrelated concerns? No — probe logic and smoke test are both
  circuit breaker concerns.

## Wiring

- [x] This issue is implementation only. No user-facing router changes.
  One internal endpoint added: `POST /internal/smoke/circuit_breakers` (existing
  `/internal` scope, HMAC-authenticated).

## Technical Requirements

### 1. Probe configuration

Each fuse needs a probe — a lightweight check returning `:ok` or `{:error, reason}`:

| Fuse | Probe | Auth |
|------|-------|------|
| `:vision_fuse` | `GET <vision_service_url>/health` → expect HTTP 200 | None (health endpoint is unauthenticated) |
| `:scraper_fuse` | `GET <scraper_service_url>/health` → expect HTTP 200 | None |
| `:together_ai_fuse` | `GET https://api.together.xyz/v1/models` → expect HTTP 200 | Bearer `VISION_TOGETHER_API_KEY` |
| `:open_library_fuse` | `GET https://openlibrary.org/search.json?q=frankenstein&limit=1` → expect HTTP 200 | None |
| `:google_books_fuse` | `GET https://www.googleapis.com/books/v1/volumes?q=frankenstein&maxResults=1` → expect HTTP 200 | None |

Probe configs are defined in `Stacks.CircuitBreakers` alongside the `@fuses` list, as a
`@probes` map keyed by fuse atom. The probe timeout is 5 seconds (short, so a slow service
does not hold the probe loop).

### 2. Probe lifecycle

Extend `Stacks.CircuitBreakers` (or add `Stacks.CircuitBreakers.Probe` — whichever is
cleaner) to:

- Attach a `:telemetry` handler for `[:stacks, :fuse, :blown]` events in `init/1`
- On `[:stacks, :fuse, :blown]`: schedule `{:probe, fuse_name}` via
  `Process.send_after(self(), {:probe, fuse_name}, @probe_interval_ms)` (default 15_000)
- `handle_info({:probe, fuse_name}, state)`:
  - If `:fuse.ask(fuse_name, :sync) == :ok` — circuit already reset (backstop timer fired
    first); do nothing
  - Else: run the probe for `fuse_name`
    - On success: call `:fuse.reset(fuse_name)`, emit `[:stacks, :fuse, :recovered]`
      telemetry with `%{fuse_name: fuse_name, recovered_via: :probe}`
    - On failure: reschedule the next probe via `Process.send_after/3`

The `{:reset, Ms}` config in each fuse spec remains unchanged as the backstop. No fuse
configs change.

Module attribute for probe interval:
```elixir
# How often to probe a blown fuse. {reset, Ms} in each fuse spec is the backstop maximum.
@probe_interval_ms 15_000
```

### 3. New telemetry event

```elixir
:telemetry.execute([:stacks, :fuse, :recovered], %{}, %{
  fuse_name: fuse_name,
  recovered_via: :probe  # vs :timer when the backstop fires
})
```

Update `docs/technical-architecture.md` §449 to document this event alongside `:melt`
and `:blown`.

### 4. Smoke test endpoint

`POST /internal/smoke/circuit_breakers` — HMAC-authenticated (same `X-Internal-Token`
scheme as vision/scraper), test-environment only (`config :core, :env == :test` guard or
a `SMOKE_TESTS_ENABLED=true` env check).

Request body: `{}` (no params — always runs all 5 fuses)

The endpoint:
1. Reinstalls all 5 fuses with `threshold=1, reset=60_000` (blows on 2nd melt, 60s backstop)
2. For each fuse, triggers 2 real failures via the existing code paths:
   - `:vision_fuse` / `:scraper_fuse` — temporarily override service URL to `"http://localhost:1"`, call the real client twice, restore URL
   - `:together_ai_fuse` — temporarily override `together_ai_base_url` to `"http://localhost:1"`, call `TogetherClient.summarize_reviews/2` twice, restore URL
   - `:open_library_fuse` / `:google_books_fuse` — temporarily set `isbn_http_client` to `FailingHttpClient`, call `ISBNResolver.resolve/1` twice, restore
3. Asserts all 5 fuses are `:blown`
4. Probe loops are already running (triggered by `[:stacks, :fuse, :blown]` telemetry);
   waits up to 30s for all 5 to return `:ok` (polls every 500ms)
5. Returns structured JSON:

```json
{
  "result": "pass" | "fail",
  "fuses": {
    "vision_fuse":       { "blown": true, "recovered": true, "recovery_ms": 1240 },
    "together_ai_fuse":  { "blown": true, "recovered": true, "recovery_ms": 15310 },
    "open_library_fuse": { "blown": true, "recovered": true, "recovery_ms": 15280 },
    "google_books_fuse": { "blown": true, "recovered": true, "recovery_ms": 15420 },
    "scraper_fuse":      { "blown": true, "recovered": true, "recovery_ms": 1180 }
  }
}
```

Vision and scraper should recover quickly (probe hits real `/health` endpoints); Together AI
and ISBN resolvers probe real external APIs so recovery time is 1–15 seconds depending on
network.

After completion (pass or fail), reinstall production fuse configs via
`Stacks.CircuitBreakers.install_all()`.

### 5. Smoke test script

`scripts/smoke-circuit-breakers.sh`:
- Posts to `$BASE_URL/internal/smoke/circuit_breakers` with HMAC token
- Exits 0 on `"result": "pass"`, exits 1 on failure or timeout
- Invocable from the deploy pipeline after the health check passes

### 6. `FailingHttpClient` availability

`Stacks.CircuitBreakersTest.FailingHttpClient` is currently defined in the test file.
Extract it to `test/support/failing_http_client.ex` so it can be referenced from the
smoke endpoint (which runs in non-test environments where test files are not compiled).
Guard the smoke endpoint with `if Application.get_env(:core, :smoke_tests_enabled, false)`.
Configure `smoke_tests_enabled: true` in `config/dev.exs` and the preview environment;
leave it false in production.

## Reviewer Context

- `:fuse.reset/1` immediately closes the circuit — it does not go through half-open. The
  probe IS the half-open probe; by the time we call `reset/1`, we have confirmed the service
  is up. This is a valid implementation of the half-open pattern even without a native
  half-open state in `:fuse`.
- The `{:reset, Ms}` timer in each fuse spec fires regardless of probe state. If the probe
  loop is running and the timer fires first, `:fuse.ask(name, :sync)` returns `:ok` and the
  probe handler is a no-op. No double-reset risk.
- The telemetry handler attached in `init/1` must use a stable handler ID (e.g. the module
  name as a string) to avoid leaking handlers on GenServer restarts.
- The smoke endpoint runs against real external APIs for Together AI, Open Library, and
  Google Books probes. In an offline CI environment it will time out on those three. This
  is acceptable — the smoke test is a deploy-time check, not a CI check.
- `FailingHttpClient` must be accessible in dev/preview but NOT compiled into production.
  The `smoke_tests_enabled` config gate achieves this without a compile-time guard.

## Definition of Done

- [ ] `Stacks.CircuitBreakers` subscribes to `[:stacks, :fuse, :blown]` and schedules probes
- [ ] Probe config defined for all 5 fuses
- [ ] On probe success: `:fuse.reset(name)` called, `[:stacks, :fuse, :recovered]` emitted
- [ ] On probe failure: next probe rescheduled
- [ ] `{:reset, Ms}` backstop still fires if probe never succeeds
- [ ] `POST /internal/smoke/circuit_breakers` endpoint implemented and HMAC-gated
- [ ] Smoke endpoint blows all 5 fuses, waits for probe-driven recovery, returns structured result
- [ ] `scripts/smoke-circuit-breakers.sh` implemented
- [ ] `FailingHttpClient` extracted to `test/support/`
- [ ] `[:stacks, :fuse, :recovered]` documented in arch doc
- [ ] `docs/runbooks/circuit-breakers.md` updated: probe recovery section, `recovered_via` field
- [ ] Unit tests: probe schedules on blow, probe resets on success, probe reschedules on failure, backstop timer still fires
- [ ] `just verify` passes

## Dependencies

Issue #136 (circuit breakers install and telemetry) — must be complete and merged first.

## Agent Assignment

`elixir-agent`

## Progress Notes

[Updated by agents during execution.]
