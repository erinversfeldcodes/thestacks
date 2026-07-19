# Issue #110: E2E Cost Data Fixture

## Summary
Ensure cost data exists on preview deployments so the Cost Transparency E2E test doesn't depend on cron timing.

## Goal
The costs page test relies on `RefreshCostsJob` having run. After removing the boot `Task.start` (#101), preview deploys have no cost data until the daily cron fires at 06:00 UTC. The test currently handles empty state gracefully, but ideally the data should always exist.

## Options

### Option A: Seed cost data
Add cost records to `priv/repo/seeds.exs` so preview deploys always have cost data. Simplest approach — cost data is static/demo anyway.

### Option B: Pre-test API call
Add a setup step in the E2E test that triggers a cost refresh via the API before assertions. Requires an admin endpoint to trigger the job.

### Option C: Deploy script trigger
Add a `fly machine exec` call to `deploy-stack.sh` that runs `Stacks.Release.refresh_costs()` after seeding. Similar to how migrations are run post-deploy.

## Recommendation
Option A (seed data) is simplest and most reliable. Cost records are deterministic demo data.

## Scope Check
- Modify seeds.exs to include platform_costs records
- ~20 LOC

## Feature-Completeness Pre-Check

Not "n/a": this fixture exists to make the **US-5.1 Cost Transparency** happy path provable
end-to-end. Per the `feature-completeness` skill, an infra/pipeline deliverable is "built"
only when a **real signal traverses the whole path and is observed at the far end** — not
when the producing code exists. Traced + live-driven 2026-07-19:

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-5.1 Cost Transparency (`/costs`) | API route `core_web/router.ex:102` → `CostController.index` → `Stacks.Costs.cost_breakdown/0` (`costs.ex:205`) → `current_period_costs/0` reads `op.platform_costs` for current month (`costs.ex:27`) → SPA route `Route.elm:172` → `Page/CostTransparency.elm` (fetch `:118`, `costs-content` `:205`, `costs-category-card` `:302`, story cards `:280`) → reachable `About.elm:29` (`about-costs-link`) | After running `RefreshCostsJob` locally to populate current-month rows: `GET /api/costs` → `total_cents=1168`, 4 categories/5 items; real browser `/costs` renders **"$11.68"** banner, **4** category cards, **3** story cards (screenshot captured) | 🟡 **PARTIAL** on preview → ✅ after #110 | **Build in-scope (this issue).** Render pipeline is ✅ built & observed live; the only unbuilt hop is the real signal (cost rows) reaching the preview store. #110's seed fixture is that in-scope build. Not de-scoped. |

**Conclusion:** the feature is built and correct; #110 closes the one 🟡 hop. Because the
fixture is the thing that makes the far-end signal appear, it must itself be protected by a
test (see the Test Audit / DoD below) — a seed that silently stops populating current-period
rows would revert this cell to 🟡 with no unit-level alarm.

## Test Audit

This fixture is audit-relevant, not audit-bearing: it unblocks the cost
dashboard cells (Layer 13, cost tracking) of the **#119 metrics/RSS test
audit** (embedded in the Test Audit section of `issues/119-e2e-metrics-rss.md`;
pattern: `plans/test-audit-plan.md`). When this fixture lands, the #119
audit's Layer-13 happy-path cells must flip from `⚠️`/`❌ — no fixture data
on preview (blocked on #110)` to `✅` with the un-conditionalised costs E2E
test named in the cell. This issue carries no embedded audit of its own;
its DoD is satisfied by greening the relevant #119 cells.

## Definition of Done
- [ ] Preview deploys have cost data immediately after seeding
- [ ] Costs E2E test passes without the `hasCostData` conditional
- [ ] Fixture is protected by an Elixir test: after the seed cost-data path runs against a
      fresh DB, `Stacks.Costs.current_period_costs/0` returns the current-month line items with
      `total_cents > 0` and every row's period inside the current calendar month (guards against
      period-drift silently emptying the E2E) — evidence: new test file:line
- [ ] Fixture cost-item logic lives in a testable `Stacks.Costs` function (not raw rows inside
      `seeds.exs`), so the above test exercises the real seed path — evidence: function + caller
- [ ] `just verify` passes
- [ ] #119 audit Layer-13 cells updated to `✅` citing the un-conditionalised costs E2E test
- [ ] Feature-Completeness Pre-Check (above) is ✅ for US-5.1 — happy path built end-to-end and
      observed working on a live stack (banner amount + category cards render from real
      `op.platform_costs` data)

## Agent Assignment
elixir-agent
