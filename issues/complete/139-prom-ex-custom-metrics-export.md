# Issue #139: Custom `stacks_*` metrics not exported via PromEx — SLO gate false-passes

## Summary
The release workflow's SLO gate scrapes `/internal/metrics` for `stacks_router_dispatch_stop_duration_milliseconds_bucket`, `stacks_upload_terminal_count_total`, and `stacks_fuse_state_state`. None of these are actually in the export, so every SLI that references them reports `value=0` and passes its `<= threshold` check trivially. The gate is currently a false-pass machine.

## User Stories
N/A (platform).

## Goal
Gate SLIs reflect real production signals. Breached = real, passed = real.

## Root cause

`CoreWeb.Telemetry.metrics/0` (`apps/core/lib/core_web/telemetry.ex`) defines `Telemetry.Metrics` entries for the three custom events:
- `summary("stacks.router_dispatch.stop.duration", tags: [:route, :route_group])`
- `counter("stacks.upload.terminal", tags: [:outcome])`
- `last_value("stacks.fuse.state", tags: [:fuse_name])`

But these definitions are never reached by a reporter that exports to Prometheus text format. `Core.PromEx.plugins/0` only lists the standard plugins:

```elixir
def plugins do
  [
    Plugins.Application,
    Plugins.Beam,
    {Plugins.Phoenix, router: CoreWeb.Router, endpoint: CoreWeb.Endpoint},
    {Plugins.Ecto, repos: [Core.Repo]},
    {Plugins.Oban, oban_supervisors: [Oban]}
  ]
end
```

Custom Stacks events have no PromEx plugin. The `Telemetry.Metrics` definitions in `CoreWeb.Telemetry.metrics/0` are effectively unused — neither PromEx nor any other reporter consumes them.

Observed in Issue #136's first successful prod deploy (commit `8e5c272`): the gate produced JSON with `auth_p95_ms: 0`, `catalogue_p95_ms: 0`, `upload_p95_ms: 0`, `db_pool_queue_p95_ms: 0`, `beam_memory_bytes: 0`. Outcome `breached` only because the availability SLI failed due to an unrelated login bug.

## Technical Requirements

### Primary fix — custom PromEx plugin

New module `Core.PromEx.Plugins.Stacks` at `apps/core/lib/core/prom_ex/plugins/stacks.ex`:

```elixir
defmodule Core.PromEx.Plugins.Stacks do
  use PromEx.Plugin
  import Telemetry.Metrics

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(:stacks_app_metrics, [
        counter(
          [:stacks, :upload, :terminal, :count],
          event_name: [:stacks, :upload, :terminal],
          description: "Upload pipeline terminal outcomes",
          tags: [:outcome]
        ),
        summary(
          [:stacks, :router_dispatch, :stop, :duration, :milliseconds],
          event_name: [:stacks, :router_dispatch, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Route-dispatch latency tagged by route group",
          tags: [:route, :route_group]
        ),
        last_value(
          [:stacks, :fuse, :state, :state],
          event_name: [:stacks, :fuse, :state],
          measurement: :state,
          description: "Circuit breaker state (1 ok, 0 blown)",
          tags: [:fuse_name]
        )
      ])
    ]
  end
end
```

Add it to `Core.PromEx.plugins/0` (`apps/core/lib/core/prom_ex.ex`).

Remove the now-redundant `CoreWeb.Telemetry.metrics/0` entries that duplicate these (or keep them if they'll be consumed by a future `TelemetryMetricsPrometheus.Core` reporter — but mark them clearly with a comment).

### Parser verification pass

After the fix deploys, `curl -H "Authorization: Bearer $METRICS_SCRAPE_TOKEN" https://thestacks-core.fly.dev/internal/metrics | head -200` and cross-check that:

- `stacks_router_dispatch_stop_duration_milliseconds_bucket{le="...",route_group="auth"}` rows exist
- `stacks_upload_terminal_count_total{outcome="resolved"}` exists
- `stacks_fuse_state_state{fuse_name="vision_fuse"}` exists
- `beam_memory_total_bytes` exists — this is exported by `Plugins.Beam`; if the parser returns 0 for this, the parser itself has a bug (probably naming-variant mismatch with PromEx's format).
- Ecto queue_time metrics for `db_pool_queue_p95_ms` — verify the parser's expected name matches what `Plugins.Ecto` actually produces.

Any SLI whose expected metric name doesn't match PromEx's actual output gets a parser correction in `scripts/check-slo-gate.sh`.

### Regression test

Add a test in `test/platform/check_slo_gate_test.sh` that uses a real (or realistic) PromEx-format fixture so the parser can't drift silently again. The existing fixtures were hand-written to match what we *expected*; they don't catch this class of issue. Capture a real scrape from the prod app (sanitise dynamic values) as `test/fixtures/metrics/prom_sample_real_promex.txt` and assert the gate produces non-zero values for the expected SLIs.

## Reviewer Context
- `Core.PromEx` (`apps/core/lib/core/prom_ex.ex`) uses standard PromEx plugin patterns; adding a custom plugin is the documented extension point.
- Custom plugin must return `PromEx.MetricTypes.Event.build/2` results from `event_metrics/1` for event-driven metrics.
- `CoreWeb.Telemetry.metrics/0` was introduced in Issue #136 Phase 1 but the plumbing to PromEx was assumed, not wired.

## Definition of Done
- [ ] `Core.PromEx.Plugins.Stacks` created and added to `Core.PromEx.plugins/0`
- [ ] `/internal/metrics` scrape includes `stacks_*` metrics after deploy
- [ ] `check-slo-gate.sh` parser matches every metric name PromEx produces (live-verified)
- [ ] Real-scrape fixture added to `test/fixtures/metrics/` and asserted on in `check_slo_gate_test.sh`
- [ ] SLO gate on a healthy deploy produces non-zero values for all SLIs
- [ ] SLO gate on a known-unhealthy deploy (force_rollback=true) produces the expected breach

## Dependencies
- Issue #136 established the gate mechanics. This issue makes the gate honest.

## Agent Assignment
elixir-agent (plugin module, Application wiring), platform-agent (parser verification, fixture, gate test).

## Progress Notes
2026-04-19: Issue created after Issue #136's first successful prod deploy revealed all latency SLIs reporting 0. Deferred behind #136's merge so the release mechanics can land; this issue is the FIRST follow-up required before the gate can be trusted as a real rollback trigger.
