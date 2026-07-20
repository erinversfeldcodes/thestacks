# Issue #259: Extract shared Costs.build_cost_items/3 to de-duplicate seed vs RefreshCostsJob

## Summary
`Stacks.Costs.seed_current_period_costs/0` (added in #110) hand-copies the 5 platform cost line
items — services, descriptions, and amounts (534/534/0/0/100) — from
`Stacks.Workers.RefreshCostsJob.build_cost_items/3`. Extract a single shared builder so the two
writers can't silently diverge.

## User Stories
None — refactor / drift-risk cleanup.

## Goal
One source of truth for the platform cost line items: `Costs.build_cost_items(period_start,
period_end, vision_jobs)`. `RefreshCostsJob` calls it with its live `vision_jobs_this_month/0`
count; the seed calls it with `0`. No behaviour change to either caller.

## Scope Check
- Controllers 0, endpoints 0, ~production LOC net-neutral (moves a list, adds one function). No split.

## Wiring
Implementation only (context refactor) — no router wiring, not user-facing.

## Feature-Completeness Pre-Check
n/a — no user stories (internal refactor).

## Background / Why (from #110 review)
Both the elixir-reviewer and the Principal Engineer flagged this on #110 as a low-severity P3:
- Drift path: change `@fly_core_cents` (etc.) in `RefreshCostsJob` → the cron produces new values,
  but `seed_current_period_costs/0` still emits 534 and `costs_test.exs` still pins 1168, so seed
  and cron diverge silently.
- Blast radius is small/self-healing (shared conflict target `[:service, :period_start,
  :period_end]` → the daily cron overwrites seeded rows in place within a day; the E2E asserts only
  `"$"` + card counts, never the literal 1168), which is why it was deferred from #110 rather than
  scope-crept.
- The PE confirmed the extraction is mechanical and byte-safe: the job's `"#{vision_jobs} inferences"`
  renders "0 inferences" for `vision_jobs: 0`, matching the seed's current hardcoded description.

## Technical Requirements
- Add `Costs.build_cost_items/3` (or similar) as the single definition of the 5 items. Keep the
  pricing constants where they are sourced (module attrs in `RefreshCostsJob`) OR move them into the
  context — reviewer's call; the requirement is one list, not two.
- `RefreshCostsJob.perform/1` calls the shared builder with the live `vision_jobs` count.
- `seed_current_period_costs/0` calls the shared builder with `0`.
- No change to: the 5 services/categories, the period formula, the `upsert_cost/1` conflict target,
  or the emitted `costs.refreshed` event.

## Reviewer Context
- `refresh_costs_job_test.exs` and `costs_test.exs` (incl. the #110 `seed_current_period_costs/0`
  block that pins 1168) must both stay green — they now share the extracted builder, so the 1168 pin
  becomes a real cross-writer guarantee rather than a coincidence.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 5 (Oban job) + context | yes | ✅ `costs_test.exs` `describe "build_cost_items/3"` pins the shared definition (0→5 items/[534,534,0,0,100]/sum 1168/"0 inferences"; 7→Modal 21/"7 inferences"); `refresh_costs_job_test.exs` + seed tests stay green (19/0). |
| others | no | n/a — pure refactor, no behaviour change |

## Definition of Done
- [x] Single `Costs.build_cost_items/3`; both `RefreshCostsJob` and `seed_current_period_costs/0` call it — evidence: `costs.ex:226` (builder) + `refresh_costs_job.ex:29` (job caller) + `costs.ex:289` (seed pipe); commit `1c3e9aa5`
- [x] `refresh_costs_job_test.exs` + `costs_test.exs` green — evidence: `just run mix test …/costs_test.exs …/refresh_costs_job_test.exs` → `19 tests, 0 failures`; full verify `2747 tests, 0 failures`
- [x] No behaviour change (same items/period/conflict/event) — evidence: elixir-reviewer APPROVED "byte-identical"; `costs.refreshed` event + `upsert_cost/1` conflict target + period formula untouched in diff
- [x] `just verify` passes — evidence: `V259_EXIT=0` (elixir 2747/0, elm-review 0, elm-test 867/0, dbt 231/231, credo/dialyzer/proto ✅)

## Dependencies
Depends on #110 (introduces `seed_current_period_costs/0`). Do after #110 merges.

## Agent Assignment
elixir-agent

## Progress Notes
- 2026-07-19: Filed from #110's 2C reviewer + 2F PE notes (low-severity DRY drift risk), deferred
  from #110 per scope-lock.
