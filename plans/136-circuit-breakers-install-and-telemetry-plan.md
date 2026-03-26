# Plan: Circuit Breakers — Install at Startup and Consistent Telemetry
**Issue**: #136
**Created**: 2026-03-26
**Status**: Approved

## Context

Every external HTTP call in the codebase is guarded by a Fuse circuit breaker check, but none of
the fuses are actually installed at application startup. In production every `:fuse.ask` returns
`{:error, :not_found}` and silently falls through to make the request — the circuit breaker
protection is completely inoperative. This issue wires the fuses at startup, consolidates the
`melt_fuse/1` helper, and adds meaningful tests that blow circuits via real failure paths.

## Research Summary

**Current state:**
- 6 fuses referenced across 4 modules: `AI.Client` (`:vision_service`), `AI.TogetherClient`
  (`:together_ai_fuse`), `Books.ISBNResolver` (`:isbn_resolver_open_library`,
  `:isbn_resolver_google_books`), `Enrichment.ScraperClient` (`:scraper_service`),
  `Workers.TriggerPriceScrapeJob` (`:scraper_fuse`).
- `AI.Client` and `Enrichment.ScraperClient` already have a private `melt_fuse/1` with telemetry.
- `AI.TogetherClient`, `Books.ISBNResolver`, and `Workers.TriggerPriceScrapeJob` use raw
  `:fuse.melt/1` with no telemetry.
- All 5 modules have `{:error, :not_found}` fallthrough branches that bypass the breaker.
- `Core.Application` does not start any fuse installation process.
- No `Stacks.CircuitBreakers` module exists.

**Human-approved design decisions (overrides initial research):**
- All fuse names standardised to `_fuse` suffix:
  - `:vision_service` → `:vision_fuse`
  - `:together_ai_fuse` → keep as-is
  - `:scraper_service` → collapsed into `:scraper_fuse` (see consolidation below)
  - `:isbn_resolver_open_library` → `:open_library_fuse`
  - `:isbn_resolver_google_books` → `:google_books_fuse`
- **Scraper fuse consolidation**: The job-level fuse guard is removed from `TriggerPriceScrapeJob`
  entirely. `:scraper_fuse` and `:scraper_service` tracked the same underlying failures from two
  layers — redundant and confusing. `ScraperClient` is the right owner (HTTP client level).
  After consolidation: `ScraperClient` uses `:scraper_fuse` (renamed from `:scraper_service`);
  `TriggerPriceScrapeJob` removes its fuse check and raw `:fuse.melt` call, treating
  `{:error, :circuit_open}` from `ScraperClient` the same as any scrape error.
- **Result: 5 fuses total** (not 6): `:vision_fuse`, `:together_ai_fuse`, `:open_library_fuse`,
  `:google_books_fuse`, `:scraper_fuse`.
- Per-store fuses (as the architecture doc specifies) are explicitly deferred to a follow-on issue.

**No existing circuit breaker tests.**

## Approach Options

- **Option A (chosen): Single `Stacks.CircuitBreakers` GenServer module** — owns startup install
  of all 5 fuses and exposes the shared `melt/1` helper. All clients delegate to it. Clean
  separation, single point of change, aligns with issue spec. Recommended.
- **Option B: Install in each client's `init/1`** — scatter install calls across 4 modules.
  Harder to audit, no ordering guarantee, doesn't consolidate `melt` helper. Not recommended.
- **Option C: Config-driven via a Mix release step** — over-engineered for runtime state.
  Not recommended.

## Phases

### Phase 1: Implement Stacks.CircuitBreakers and wire everything up
**Objective**: Create the shared `Stacks.CircuitBreakers` module, wire it in `Core.Application`,
rename all fuse atoms, consolidate the scraper fuse, replace all raw `:fuse.melt` calls with the
shared helper, remove private `melt_fuse/1` helpers, and remove `{:error, :not_found}` fallthrough
branches.
**Agent(s)**: elixir-agent
**Steps**:
1. Create `apps/core/lib/stacks/circuit_breakers.ex` with:
   - `start_link/1` / `init/1` as a GenServer that calls `:fuse.install` for all 5 fuses
     at startup using the configs from the issue (5 failures/60s → 5 min for vision/together/isbn;
     3 failures/60s → 15 min for scraper)
   - Public `melt/1` function (the shared telemetry helper)
2. Register `Stacks.CircuitBreakers` in `Core.Application` before `Stacks.AI.BudgetTracker`
3. In `AI.Client`: rename `@fuse_name` from `:vision_service` to `:vision_fuse`; remove private
   `melt_fuse/1`; replace calls with `Stacks.CircuitBreakers.melt/1`; remove
   `{:error, :not_found}` fallthrough
4. In `AI.TogetherClient`: replace raw `:fuse.melt` calls with `Stacks.CircuitBreakers.melt/1`;
   remove `{:error, :not_found}` fallthrough (fuse name unchanged: `:together_ai_fuse`)
5. In `Books.ISBNResolver`: rename `@open_library_fuse` to `:open_library_fuse` and
   `@google_books_fuse` to `:google_books_fuse`; replace raw `:fuse.melt` calls with
   `Stacks.CircuitBreakers.melt/1`; remove `{:error, :not_found}` fallthrough
6. In `Enrichment.ScraperClient`: rename `@fuse_name` from `:scraper_service` to `:scraper_fuse`;
   remove private `melt_fuse/1`; replace calls with `Stacks.CircuitBreakers.melt/1`; remove
   `{:error, :not_found}` fallthrough
7. In `Workers.TriggerPriceScrapeJob`: remove the job-level `:scraper_fuse` guard in
   `scrape_all/2` entirely; remove the raw `:fuse.melt(@fuse_name)` call in `do_scrape_all/2`;
   handle `{:error, :circuit_open}` from `ScraperClient` the same as any other error tuple
8. Write `test/stacks/circuit_breakers_test.exs` — 5 fuse tests (one per fuse), each:
   - Confirms fuse is installed (`:fuse.ask(name, :sync)` returns `:ok`)
   - Blows the circuit via enough real failures (mock HTTP returning errors, NOT direct `:fuse.melt`)
   - Asserts the client returns `{:error, :circuit_open}` on the next call
   - Asserts `[:stacks, :fuse, :blown]` telemetry fires

**Test Command**: `mix test apps/core/test/stacks/circuit_breakers_test.exs` then `mix test`
**DoD Items**:
- [ ] `Stacks.CircuitBreakers` module installs all 5 fuses in `start_link/1`
- [ ] `Stacks.CircuitBreakers.melt/1` is the single shared melt helper with telemetry
- [ ] All raw `:fuse.melt` calls replaced in `TogetherClient`, `ISBNResolver`,
      `TriggerPriceScrapeJob`
- [ ] Private `melt_fuse/1` removed from `Client` and `ScraperClient`
- [ ] `{:error, :not_found}` fallthrough branches removed from all clients
- [ ] Fuse atoms renamed: `:vision_service` → `:vision_fuse`, `:scraper_service` → `:scraper_fuse`,
      `:isbn_resolver_open_library` → `:open_library_fuse`,
      `:isbn_resolver_google_books` → `:google_books_fuse`
- [ ] Scraper fuse consolidated: `TriggerPriceScrapeJob` no longer has its own fuse guard or
      raw `:fuse.melt` call
- [ ] `Stacks.CircuitBreakers` registered in `Core.Application` before any client
- [ ] `test/stacks/circuit_breakers_test.exs` covers all 5 fuses (install confirmed, blown via
      real failure path, `[:stacks, :fuse, :blown]` telemetry fires)
- [ ] `just verify` passes

## Open Questions

None — all design decisions resolved by human approval.

## Integration Handoffs

None. This is standalone Elixir infrastructure — no database, proto, or Elm changes.
