# Plan: Emit a metric on refresh revoke-failure
**Issue**: #181  ·  **Created**: 2026-07-10  ·  **Status**: Approved

## Context
`AuthController.refresh/2` (#173) revokes the old token then mints a new one; on a `Guardian.revoke`
failure it logs a warning (`auth_controller.ex:174-175`) and still mints — leaving the old token live.
That degraded case is log-only, invisible on dashboards. Add telemetry so it's counted/alertable.

## Research Summary
- `:telemetry.execute/3` is the emission idiom (internal_controller.ex:377, upload_controller.ex:498).
- PromEx custom plugin `apps/core/lib/core/prom_ex/plugins/stacks.ex` registers metrics via
  `Event.build(:stacks_app_metrics, [counter(...)])`; `apps/core/test/core/prom_ex_custom_metrics_test.exs`
  is the telemetry test pattern (attach/execute + assert).
- Revoke-failure branch: `auth_controller.ex:174` (`error -> Logger.warning("Guardian.revoke failed during refresh…")`).

## Phases
### Phase 1: telemetry on refresh revoke-failure (elixir-agent)
1. In the refresh revoke-failure branch, emit `:telemetry.execute([:stacks, :auth, :refresh, :revoke_failed], %{count: 1}, %{})` alongside the existing `Logger.warning` (keep the warning — it carries `inspect(error)`).
2. Register a `counter` for that event in `prom_ex/plugins/stacks.ex` (mirror the existing counters).
3. Test: attach a telemetry handler and assert the event fires when the refresh revoke-failure branch runs (force the failure — e.g. stub/inject a revoke error, or exercise the branch directly). Follow `prom_ex_custom_metrics_test.exs`.
**DoD**: event fires on the branch; registered as a PromEx counter; telemetry test; `just verify`.

## Gate Plan
- 2B-i `just verify` (elixir). 2B-ii spec coverage. 2B-iia skip (no DB). **2B-iii skip** — observability
  change, no deployed-behaviour surface; ExUnit telemetry test is the validation path. 2F PE: optional
  (tiny); skip or fold into review. 2C: elixir-reviewer.

## Dependencies
#173 (the refresh revoke-failure branch). Agent: elixir-agent.
