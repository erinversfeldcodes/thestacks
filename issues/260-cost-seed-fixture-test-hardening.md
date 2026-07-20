# Issue #260: Cost-seed fixture test hardening — telemetry assertion + month-scoping

## Summary
Close the two test-coverage residuals #110's retro flagged on the cost-seed fixture: (1) assert the
`[:stacks, :costs, :recorded]` telemetry the seed emits, and (2) pin the intended month-scoping of
`Stacks.Costs.current_period_costs/0`. Both are test-only; no production behaviour change.

## User Stories
None — test-hardening of the #110 fixture. Still validatable: both behaviours get a unit test at
the layer that actually proves them (telemetry emission + query scoping are backend-only; Playwright
is the wrong tool).

## Goal
The two residuals from `plans/110-e2e-cost-data-fixture-retro.md` are covered so the fixture's
Layer-11 side effect and Layer-13 month-scoping are **intentional-and-tested**, not latent surprises.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Controllers: 0 (✓ not split). Endpoints: 0 (✓). Production LOC: ~0, ~40 LOC of tests (✓ well under 300).
- Mixed concerns? No — both items harden the *same* cost-seed fixture's test coverage. One concern, one issue.

## Wiring
Implementation only (tests) — no router/UI wiring, not user-facing.

## Feature-Completeness Pre-Check
n/a — no user stories; the feature (cost data on `/costs`) is already built and validated by #110.
This issue only adds test coverage of two existing behaviours.

## Technical Requirements
1. **Telemetry assertion (Layer 11).** `Stacks.Costs.upsert_cost/1` fires
   `:telemetry.execute([:stacks, :costs, :recorded], %{amount_cents: …}, %{category: …, service: …})`
   on each `{:ok, cost}` (`apps/core/lib/stacks/costs.ex:184-190`). `seed_current_period_costs/0`
   upserts 5 items, so it must emit 5 such events. Add a test that attaches a handler (mirror the
   `attach_telemetry/1` pattern in `apps/core/test/stacks/observability_telemetry_test.exs`), calls
   `seed_current_period_costs/0`, and asserts **5** `[:stacks, :costs, :recorded]` events arrive,
   each with an `amount_cents` measurement and `category`/`service` metadata.
2. **Month-scoping (Layer 13).** `current_period_costs/0` filters
   `period_start >= beginning_of_month(now) and period_end <= end_of_month(now)`
   (`apps/core/lib/stacks/costs.ex:27-36`). Add a test pinning **both directions**: a cost row
   stamped for a *different* calendar month (e.g. last month) is **excluded**, while current-month
   rows are returned. This documents the known preview month-boundary limitation (retro: rows stamped
   to seed-time month → `/costs` empties across a boundary until the 06:00 cron) as intended, tested
   behaviour. **No change to `current_period_costs/0` behaviour** — test only.
- Both tests live in `apps/core/test/stacks/costs_test.exs`. No production code changes.

## Reviewer Context
- The telemetry test must assert exactly 5 emissions (one per seeded line item), not ≥1 — a vacuous
  `≥1` would not catch a partial-seed regression.
- The month-scoping test must construct the off-month row directly (factory/insert with an explicit
  prior-month `period_start`/`period_end`), not via `seed_current_period_costs/0` (which always
  stamps the current month). Use `insert(:platform_cost, …)` or `Repo.insert` with `PlatformCost`.
- Cost data is aggregate platform data — no GDPR surface (no PII, no user FK).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 11 (operational metrics — `costs.recorded` telemetry) | yes | ✅ `costs_test.exs` "emits exactly 5 [:stacks, :costs, :recorded] events, one per line item" — attaches handler, asserts exactly 5 (`refute_receive` a 6th), each with `amount_cents` + `category`/`service`, matching the 5 seeded services |
| 13 (cost tracking — month-scoping of `current_period_costs/0`) | yes | ✅ `costs_test.exs` "includes current-month rows and excludes a prior-month row" — prior-month row (inserted directly) excluded by service AND id; current-month rows returned (`length==5`) |
| 1–10, 12 | no | n/a — test-only hardening of an existing fixture; no new runtime surface |

Punch list:
1. L11 — telemetry emission test (5× `[:stacks, :costs, :recorded]` on seed) → `apps/core/test/stacks/costs_test.exs`.
2. L13 — month-scoping both-directions test (off-month excluded, current-month returned) → `apps/core/test/stacks/costs_test.exs`.

## Definition of Done
- [x] Test asserts `seed_current_period_costs/0` emits `[:stacks, :costs, :recorded]` exactly 5× with `amount_cents` measurement + `category`/`service` metadata — evidence: `apps/core/test/stacks/costs_test.exs:346` "emits exactly 5 [:stacks, :costs, :recorded] events, one per line item" (18/0)
- [x] Test pins `current_period_costs/0` month-scoping — a different-month row is excluded, current-month rows returned — evidence: `apps/core/test/stacks/costs_test.exs:386` "includes current-month rows and excludes a prior-month row" (refutes by service + id; asserts `length==5`)
- [x] No production behaviour change — evidence: `git status --short apps/core/lib` empty; only `apps/core/test/stacks/costs_test.exs` modified (module also flipped `async: true`→`false` for telemetry-count safety, mirroring `observability_telemetry_test.exs`)
- [x] Every behaviour has a validation path — both covered by unit tests at the proving layer (telemetry/query scoping are backend-only; Playwright n/a) — evidence: the two tests above
- [x] `just verify` passes — evidence: exit 0 (elixir 2749/0, elm-review 0, elm-test 867/0, dbt 231/231, credo/dialyzer/proto ✅)
- [x] Test audit (above) GREEN — every applicable cell `✅` — evidence: L11 + L13 cells above flipped to ✅

## Dependencies
Depends on #110 (introduces `seed_current_period_costs/0`) — #110 complete (commit `8abe3adc`). Both
items are from #110's retro (`plans/110-e2e-cost-data-fixture-retro.md`).

## Agent Assignment
elixir-agent

## Progress Notes
- 2026-07-20: Filed from #110 retro residuals (telemetry assertion + month-scoping). Test-only, on
  feat/110-e2e.
