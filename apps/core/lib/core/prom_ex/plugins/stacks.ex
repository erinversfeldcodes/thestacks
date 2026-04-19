defmodule Core.PromEx.Plugins.Stacks do
  @moduledoc """
  PromEx plugin that exports The Stacks' custom `[:stacks, ...]` telemetry
  events to Prometheus.

  Without this plugin, the `Telemetry.Metrics` entries declared by
  `CoreWeb.Telemetry.metrics/0` have no reporter — PromEx only consumes
  metrics returned by its registered plugins. The SLO gate scraper
  (`scripts/check-slo-gate.sh`) reads `/internal/metrics` and expects
  three Stacks-namespaced metric families to exist at these exact names:

    * `stacks_upload_terminal_count_total` — upload pipeline outcomes
    * `stacks_router_dispatch_stop_duration_milliseconds_{bucket,sum,count}`
      — route-dispatch latency, tagged by `:route_group`
    * `stacks_fuse_state_state` — circuit breaker state gauge

  Because `TelemetryMetricsPrometheus.Core` does not append `_total` to
  counters automatically, the counter metric path below ends in
  `[:count, :total]` so the exported series name matches what the gate
  parser reads. The distribution path ends in `[:duration, :milliseconds]`
  so the `_bucket`/`_sum`/`_count` triple is produced under the expected
  base name.

  See Issue #139 for background.
  """

  use PromEx.Plugin

  # `use PromEx.Plugin` already imports `counter/2`, `distribution/2`,
  # `last_value/2`, and `sum/2` from `Telemetry.Metrics`.

  # Buckets aligned with the `le=` values baked into the existing gate
  # fixtures (`test/fixtures/metrics/prom_sample_healthy.txt`) and the
  # route-group p95 thresholds (auth/catalogue 500ms, upload 2000ms).
  @route_duration_buckets [50, 100, 250, 500, 1_000, 2_000, 5_000]

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(:stacks_app_metrics, [
        # ── Upload pipeline terminal outcomes ─────────────────────────
        # Counter path ends in `:total` so the exported Prometheus name is
        # `stacks_upload_terminal_count_total`.
        counter(
          [:stacks, :upload, :terminal, :count, :total],
          event_name: [:stacks, :upload, :terminal],
          description: "Upload pipeline terminal outcomes (resolved/rejected/timeout).",
          tags: [:outcome]
        ),

        # ── Route-dispatch latency by route group ─────────────────────
        # Distribution path ends in `[:duration, :milliseconds]` so the
        # exporter emits `_bucket`/`_sum`/`_count` suffixes under
        # `stacks_router_dispatch_stop_duration_milliseconds`.
        distribution(
          [:stacks, :router_dispatch, :stop, :duration, :milliseconds],
          event_name: [:stacks, :router_dispatch, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Phoenix route-dispatch latency tagged by route group.",
          tags: [:route_group],
          reporter_options: [buckets: @route_duration_buckets]
        ),

        # ── Fuse state gauge ──────────────────────────────────────────
        # `last_value` maps to Prometheus gauge type. Path ends in
        # `[:state, :state]` so the exported name is
        # `stacks_fuse_state_state`.
        last_value(
          [:stacks, :fuse, :state, :state],
          event_name: [:stacks, :fuse, :state],
          measurement: :state,
          description: "Circuit breaker state (1 = healthy, 0 = blown).",
          tags: [:fuse_name]
        )
      ])
    ]
  end
end
