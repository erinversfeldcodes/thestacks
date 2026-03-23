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

## Definition of Done
- [ ] Preview deploys have cost data immediately after seeding
- [ ] Costs E2E test passes without the `hasCostData` conditional
- [ ] `just verify` passes

## Agent Assignment
elixir-agent
