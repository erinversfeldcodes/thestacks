# Issue #136: Circuit Breakers — Install at Startup and Consistent Telemetry

## Summary

The architecture specifies circuit breakers on every external HTTP call. None of the fuses are
installed at application startup. In production every `:fuse.ask` returns `{:error, :not_found}`
and falls through to make the request — the circuit breakers are completely non-functional.
Additionally, telemetry on melt/blown events is inconsistent across clients.

## User Stories

- US-1.1.1 (upload pipeline resilience — vision service down should produce retriable Oban error,
  not burn all 3 attempts on an already-dead service)
- US-2.1.1 (reviews — Together AI circuit should protect against runaway API spend)
- US-2.2.1 (prices — scraper circuit should skip a down store, not fail the whole job)
- Underpins all external service reliability (Open Library, Google Books, Brave Search)

## Full Scope of This Principle

Per `docs/technical-architecture.md` § "Circuit Breakers on External Services", every external
HTTP call is wrapped in a Fuse circuit breaker. Current state of each:

| Fuse name | Module | Installed at startup | Telemetry on melt | Telemetry on blown |
|---|---|---|---|---|
| `:vision_service` | `Stacks.AI.Client` | ✗ | ✓ (via `melt_fuse/1`) | ✓ (via `melt_fuse/1`) |
| `:together_ai_fuse` | `Stacks.AI.TogetherClient` | ✗ | ✗ (raw `:fuse.melt`) | ✗ |
| `:open_library_fuse` | `Stacks.Books.ISBNResolver` | ✗ | ✗ (raw `:fuse.melt`) | ✗ |
| `:google_books_fuse` | `Stacks.Books.ISBNResolver` | ✗ | ✗ (raw `:fuse.melt`) | ✗ |
| `:scraper_fuse` | `Stacks.Workers.TriggerPriceScrapeJob` | ✗ | ✗ (raw `:fuse.melt`) | ✗ |
| `:scraper_service` | `Stacks.Enrichment.ScraperClient` | ✗ | ✓ (via `melt_fuse/1`) | ✓ (via `melt_fuse/1`) |
| `:brave_search_fuse` | Not yet created | ✗ | ✗ | ✗ |

**All are deferred to this issue.** The Brave Search fuse is in scope for creation when the
Brave Search client is implemented; the others are in scope now.

## Goal

Every circuit breaker:
1. Is installed at application startup with the config from the architecture doc
2. Emits `[:stacks, :fuse, :melt]` and `[:stacks, :fuse, :blown]` telemetry consistently on
   every state change, regardless of which code path triggers the melt
3. Is verified by a test that blows the circuit through a realistic failure path (not by calling
   `:fuse.melt` directly in a test and hoping the telemetry fires)

## Scope Check

- Does this issue touch more than 3 controllers? No (no controllers touched).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? Likely close — if it does, split
  `ISBNResolver` fuses and `TogetherClient` fuse into a follow-up.
- Does this issue combine unrelated concerns? No (all circuit breaker wiring).

## Wiring

- [x] This issue is implementation only. No router changes.

## Technical Requirements

### 1. Install all fuses at startup

Add a `Stacks.CircuitBreakers` module (a plain `GenServer` or a simple `start_link` that
calls `:fuse.install` for each fuse and returns `:ignore` if already installed). Register it
in `Core.Application` before any client that depends on it. Use configs from the arch doc:

```elixir
# Modal vision — 5 failures in 60s → open 5 min
:fuse.install(:vision_service,   {{:standard, 5, 60_000}, {:reset, 300_000}})
# Together AI — 5 failures in 60s → open 5 min
:fuse.install(:together_ai_fuse, {{:standard, 5, 60_000}, {:reset, 300_000}})
# Open Library — 5 failures in 60s → open 5 min
:fuse.install(:open_library_fuse, {{:standard, 5, 60_000}, {:reset, 300_000}})
# Google Books — 5 failures in 60s → open 5 min
:fuse.install(:google_books_fuse, {{:standard, 5, 60_000}, {:reset, 300_000}})
# Scraper service — 3 failures in 60s → open 15 min
:fuse.install(:scraper_service,  {{:standard, 3, 60_000}, {:reset, 900_000}})
# Scraper orchestrator fuse
:fuse.install(:scraper_fuse,     {{:standard, 3, 60_000}, {:reset, 900_000}})
```

### 2. Consistent telemetry via a shared helper

Extract the `melt_fuse/1` pattern from `Client` into a shared module (e.g.
`Stacks.CircuitBreakers`) so all clients use the same implementation:

```elixir
def melt(fuse_name) do
  :fuse.melt(fuse_name)
  case :fuse.ask(fuse_name, :sync) do
    :blown -> :telemetry.execute([:stacks, :fuse, :blown], %{}, %{fuse_name: fuse_name})
    _      -> :telemetry.execute([:stacks, :fuse, :melt],  %{}, %{fuse_name: fuse_name})
  end
end
```

Replace all raw `:fuse.melt(name)` calls in `TogetherClient`, `ISBNResolver`, and
`TriggerPriceScrapeJob` with `Stacks.CircuitBreakers.melt(name)`.

Remove the now-duplicated private `melt_fuse/1` from `Client` and `ScraperClient`.

### 3. Remove `{:error, :not_found}` fallthrough comments

Once fuses are installed at startup, the `{:error, :not_found}` branch in each client
is dead code. Remove it to prevent silent bypass if installation is ever accidentally skipped.

### 4. Tests

For each fuse, one test that:
- Confirms the fuse is installed (`:fuse.ask(name, :sync)` returns `:ok`, not `{:error, :not_found}`)
- Blows the circuit by triggering enough real failures (via mock HTTP client returning errors),
  not by calling `:fuse.melt` directly
- Asserts the affected client returns `{:error, :circuit_open}` on the next call
- Asserts `[:stacks, :fuse, :blown]` telemetry fires

Tests go in `test/stacks/circuit_breakers_test.exs`.

## Reviewer Context

- `melt_fuse/1` currently exists privately in both `Client` and `ScraperClient` — the
  refactor consolidates these into `Stacks.CircuitBreakers.melt/1`. The shared module also
  owns `install_all/0` called at startup.
- `:fuse.install/2` is idempotent-safe if called with `if :fuse.ask(name, :sync) == {:error, :not_found}` guard — or use a `try/rescue` on the already-installed case.
- The `:scraper_fuse` (in `TriggerPriceScrapeJob`) and `:scraper_service` (in `ScraperClient`)
  are two separate fuses on the same conceptual service path. Verify intended behaviour before
  merging them.

## Architecture Alignment

`docs/technical-architecture.md` § "Circuit Breakers on External Services" (line ~4764) is the
authoritative spec. The fuse configs in this issue are taken directly from that table. After this
issue, every row in that table has a corresponding installed fuse.

## Definition of Done

- [ ] `Stacks.CircuitBreakers` module installs all 5 fuses in `start_link/1`
- [ ] `Stacks.CircuitBreakers.melt/1` is the single shared melt helper
- [ ] All raw `:fuse.melt` calls replaced in `TogetherClient`, `ISBNResolver`, `TriggerPriceScrapeJob`
- [ ] Private `melt_fuse/1` removed from `Client` and `ScraperClient`
- [ ] `{:error, :not_found}` fallthrough branches removed from all clients
- [ ] `Stacks.CircuitBreakers` registered in `Core.Application` before any client
- [ ] `test/stacks/circuit_breakers_test.exs` covers all 5 fuses (install confirmed, blown via real failure path, telemetry fires)
- [ ] `just verify` passes

## Dependencies

None. This is standalone infrastructure work.

## Agent Assignment

`elixir-agent`

## Progress Notes

[Updated by agents during execution.]
