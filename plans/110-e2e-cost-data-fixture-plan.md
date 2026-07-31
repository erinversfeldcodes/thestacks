# Plan: E2E Cost Data Fixture
**Issue**: #110
**Created**: 2026-07-19
**Status**: Approved

## Context
The `/costs` Cost Transparency page depends on `RefreshCostsJob` having populated
`op.platform_costs`. After the boot-time seed `Task.start` was removed (#101), preview deploys
have no cost data until the daily cron fires at 06:00 UTC, so `e2e/tests/costs.spec.ts` gates all
cost-value assertions behind a `hasCostData` conditional that never executes on preview. This issue
seeds current-period cost data so the data always exists, and un-conditionalises the E2E.

## Research Summary
- Feature is **built** end-to-end (traced + live-driven): API route `core_web/router.ex:102` →
  `CostController.index` → `Stacks.Costs.cost_breakdown/0` (`costs.ex:205`) →
  `current_period_costs/0` (`costs.ex:27`, **filters to current calendar month**) → SPA
  `Route.elm:172` → `Page/CostTransparency.elm` → reachable via `About.elm:29`. Live drive after
  running `RefreshCostsJob` locally: `/api/costs` `total_cents=1168`, 4 categories/5 items; browser
  `/costs` rendered "$11.68" banner, 4 category cards, 3 story cards.
- Verdict: US-5.1 is 🟡 PARTIAL on preview (render pipeline built; the real signal never reaches the
  preview store) → ✅ after #110. Resolution: build in-scope.
- **Key subtlety:** `current_period_costs/0` is month-bounded, so the seed must compute
  `period_start`/`period_end` for the *current* month at seed time, with the *same* formula as
  `Costs`/`RefreshCostsJob` (`{0,6}` / `{999_999,6}` microseconds) so the daily cron's `on_conflict`
  target `[:service, :period_start, :period_end]` updates in place rather than duplicating rows.
- **Sufficiency gap:** the as-filed DoD has no test protecting the fixture; existing
  `costs_test.exs`/`refresh_costs_job_test.exs` use factory data, not the seed path. A seed that
  silently stops populating current-period rows would revert the E2E to empty-state with no
  unit-level alarm. Fixed by moving the item-builder into a testable `Stacks.Costs` function + a test.
- GDPR lens: **N/A** — aggregate platform operational cost only, zero PII, no user FK, no event
  payload change.

## Approach Options
- **Option A (chosen):** Seed current-period cost data via a new **testable `Stacks.Costs`
  function** called from `seeds.exs`. Deterministic, no new surface, protects the fixture with a
  unit test. Recommended.
- **Option B:** Pre-test API call to trigger a refresh — needs a new admin endpoint (auth surface +
  network dependency in E2E). Not recommended.
- **Option C:** `fly machine exec` in `deploy-stack.sh` to run `refresh_costs` post-deploy — the
  #171/#177 512 MB `exec`/`eval` OOM footgun. Not recommended.

## Phases

### Phase 1: Testable seed fixture + un-conditionalise E2E
**Objective**: Current-period cost data is always present after seeding, protected by a unit test,
and the costs E2E asserts values unconditionally.
**Agent(s)**: elixir-agent
**Reviewers**: elixir-reviewer + contract-reviewer (fixture must match the `/api/costs` shape the E2E asserts)
**Steps**:
1. `apps/core/lib/stacks/costs.ex` — add a public function that builds + upserts the 5 static
   current-month demo line items (Modal @ 0 inferences → `amount_cents 0`), computing the month
   period identically to `current_period_costs`/`RefreshCostsJob`.
2. `apps/core/priv/repo/seeds.exs` — call that function in a `platform_costs` block (idempotent).
3. `apps/core/test/stacks/costs_test.exs` — new test: after the seed function runs against a fresh
   DB, `current_period_costs/0` returns the items, `total_cents > 0`, and every row's period lies
   inside the current calendar month (guards period-drift).
4. `e2e/tests/costs.spec.ts` — remove the `hasCostData` conditional (lines 25-43); assert banner
   `$`, ≥1 category card, exactly 3 story cards unconditionally.
5. `issues/119-e2e-metrics-rss.md` — flip Layer-13 cell (line 326) + punch-item #10 (line 347) to
   ✅, citing the un-conditionalised `costs.spec.ts`.
**Test Command**: `just run mix test apps/core/test/stacks/costs_test.exs` (elixir); `cd e2e && npx playwright test costs.spec.ts` (E2E).
**Proving gate**: fresh-DB `mix run …/seeds.exs` → `GET /api/costs` returns non-empty `categories`
with `total_cents > 0` → drive `/costs` and see the `$` banner + category cards render (observed
locally; re-proven on preview at 2B-iii), NOT merely "tests pass".
**DoD Items** (from issue, sufficiency-checked):
- [ ] Preview deploys have cost data immediately after seeding — evidence: `curl /api/costs` on preview shows populated `categories`
- [ ] Costs E2E passes without the `hasCostData` conditional — evidence: `costs.spec.ts` diff + green run
- [ ] Fixture protected by an Elixir test (current-month rows, `total_cents > 0`, period-in-month) — evidence: new test file:line
- [ ] Fixture cost-item logic lives in a testable `Stacks.Costs` function (not raw rows) — evidence: function + caller
- [ ] `just verify` passes
- [ ] #119 audit Layer-13 cells updated to ✅ citing the un-conditionalised costs E2E test
- [ ] Feature-Completeness Pre-Check ✅ for US-5.1 (banner + cards render from real data, observed live)

## Gate Sequence (none omitted)
- 2A-iv Completion Reception + testing-coordinator
- 2B-i Regression (elixir + e2e)
- 2B-ii Spec Coverage
- 2B-iia Fresh-DB — **run** (deliverable is "fresh DB → seed → data present")
- 2B-iii Deploy Preview + E2E (costs.spec.ts vs preview)
- 2F Principal Engineer (ships deployed code; not doc-only)

## Open Questions
None.

## Integration Handoffs
Single phase, single agent. elixir-agent hands the fixture shape to contract-reviewer to confirm it
matches the `/api/costs` response the E2E asserts.
