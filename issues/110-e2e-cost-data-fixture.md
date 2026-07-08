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
- [ ] `just verify` passes
- [ ] #119 audit Layer-13 cells updated to `✅` citing the un-conditionalised costs E2E test

## Agent Assignment
elixir-agent
