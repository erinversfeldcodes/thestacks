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
  #
  # 10_000 and 20_000 buckets added 2026-04-20 because upload p95 was
  # saturating the old 5000ms ceiling — the gate's histogram p95
  # computation falls back to `2 × max_finite_bucket` when the +Inf
  # bucket is the only one with counts beyond the top, which reported
  # as a flat 10000ms and hid the true latency distribution. Upload's
  # real cost profile is ~3–8s (two sequential Modal vision calls +
  # R2 upload + DB writes); anything over 20s is genuinely anomalous.
  @route_duration_buckets [50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

  # Buckets for the per-handler dispatch duration — most event
  # handlers are DB-only and complete in tens of ms; a slow one
  # (e.g. one that makes an external HTTP call) can push into the
  # seconds. The 5000/10000 upper bounds catch handlers that are
  # genuinely problematic so operators can find them in grafana/axiom.
  @dispatch_duration_buckets [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(:stacks_app_metrics, [
        # ── Event emission throughput ─────────────────────────────────
        # Fires once per `Stacks.Events.emit/1`. Tagged by event_type
        # so we can see which event flows dominate the
        # `:events` Oban queue and size the queue's concurrency
        # accordingly. Exported as `stacks_events_emitted_count_total`.
        counter(
          [:stacks, :events, :emitted, :count, :total],
          event_name: [:stacks, :events, :emitted],
          description: "Events appended to the op.event_log (pre-dispatch).",
          tags: [:event_type, :aggregate_type]
        ),

        # ── Handler invocation counter ────────────────────────────────
        # Fires every time SubscriberWorker calls a handler, regardless
        # of outcome. Labelled by handler module + event_type so
        # operators can answer "how often does each handler fire?" and
        # compare against `dispatch_duration` to find the expensive-
        # times-frequent combinations.
        counter(
          [:stacks, :events, :handler_invoked, :count, :total],
          event_name: [:stacks, :events, :handler_invoked],
          description: "Invocations of Stacks.Events handlers from SubscriberWorker.",
          tags: [:handler, :event_type]
        ),

        # ── Handler error counter (renamed from legacy path) ─────────
        # The legacy path was `[:stacks, :events, :handler_error]`;
        # PromEx's `_total` suffix convention requires the metric path
        # to end `:count, :total`. Keeps the semantics identical (fires
        # on `{:error, _}` return AND on raise) but exports cleanly as
        # `stacks_events_handler_error_count_total`.
        counter(
          [:stacks, :events, :handler_error, :count, :total],
          event_name: [:stacks, :events, :handler_error],
          description: "Handler errors (returned {:error, _} or raised).",
          tags: [:handler, :event_type]
        ),

        # ── Handler dispatch duration (histogram) ─────────────────────
        # Per-handler wall-clock time for one `handle_event/1` call.
        # Wire-format: `stacks_events_dispatch_duration_milliseconds_{bucket,sum,count}`.
        # The gate can derive a p95-by-handler SLI from this if we want
        # to gate on handler timeouts later.
        distribution(
          [:stacks, :events, :dispatch, :duration, :milliseconds],
          event_name: [:stacks, :events, :dispatch],
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Per-handler dispatch time in SubscriberWorker.",
          tags: [:handler, :event_type],
          reporter_options: [buckets: @dispatch_duration_buckets]
        ),

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
