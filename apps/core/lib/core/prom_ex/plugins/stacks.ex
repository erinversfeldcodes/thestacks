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

  # Buckets for per-query duration. Narrower than the handler
  # distribution because a single query is much smaller in scope —
  # most PG round-trips are <50ms; >500ms is already a red flag.
  # Top bucket of 5000ms catches genuinely pathological queries.
  @query_duration_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

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

        # ── Per-query duration, tagged by Oban worker ─────────────────
        # Emitted by `CoreWeb.Telemetry.handle_slow_query/4` on every
        # Ecto query event. Tags:
        #   - `worker`: Oban worker module name if the query is running
        #     inside an Oban job, "http" otherwise. Populated via
        #     process-dict tagging in `handle_oban_job_lifecycle/4`.
        #   - `source`: target table, or "(raw)" for ad-hoc SQL.
        #   - `repo`: Core.Repo vs Core.ObanRepo, for pool-attribution.
        #
        # Exported as
        # `stacks_repo_query_duration_milliseconds_{bucket,sum,count}`.
        # Answers "which worker's DB queries are dominating
        # Core.Repo's pool?" — directly actionable signal for
        # db_pool_queue_p95_ms saturation.
        distribution(
          [:stacks, :repo, :query, :duration, :milliseconds],
          event_name: [:stacks, :repo, :query, :duration],
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Per-query duration tagged by Oban worker, source table, and repo.",
          tags: [:worker, :source, :repo],
          reporter_options: [buckets: @query_duration_buckets]
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

        # ── Auth refresh revoke-failure counter (Issue #181) ──────────
        # Fires when AuthController.refresh/2 fails to revoke the old token
        # during rotation. The action still mints a fresh token (degraded
        # rotation: the old token stays valid until its TTL expires), so this
        # counter makes the degraded case alertable alongside the Logger
        # warning. Counter path ends in `:count, :total` so the exported name
        # is `stacks_auth_refresh_revoke_failed_count_total`.
        counter(
          [:stacks, :auth, :refresh, :revoke_failed, :count, :total],
          event_name: [:stacks, :auth, :refresh, :revoke_failed],
          description: "Failures to revoke the old JWT during token refresh rotation."
        ),

        # ── Auth §12 operational counters (Issue #206, #124 gap) ──────
        # Registration outcomes — `result` is a bounded label (ok|error).
        # Exported as `stacks_auth_registration_count_total{result=…}`.
        counter(
          [:stacks, :auth, :registration, :count, :total],
          event_name: [:stacks, :auth, :registration],
          description: "User registration outcomes (right-to-account creation).",
          tags: [:result]
        ),

        # JWT issuance — one per token actually handed to a client. `context`
        # is a bounded label (login|refresh) distinguishing interactive login
        # issuance from silent-renewal rotation issuance. Exported as
        # `stacks_auth_jwt_issued_count_total{context=…}`.
        counter(
          [:stacks, :auth, :jwt_issued, :count, :total],
          event_name: [:stacks, :auth, :jwt_issued],
          description: "Guardian JWTs issued, by issuance context (login vs refresh).",
          tags: [:context]
        ),

        # Login-failure-by-type — `type` is a bounded, whitelisted atom
        # (invalid_credentials|email_unconfirmed|missing_params|
        # account_locked|service_busy), NOT raw input. Exported as
        # `stacks_auth_login_failure_count_total{type=…}`.
        counter(
          [:stacks, :auth, :login_failure, :count, :total],
          event_name: [:stacks, :auth, :login_failure],
          description: "Failed login attempts, broken down by failure type.",
          tags: [:type]
        ),

        # Rate-limit rejections (Issue #206) — `bucket` is a bounded,
        # whitelisted atom set at the plug call site. The `bucket="auth"`
        # series is the 429 login-failure-by-type signal. Exported as
        # `stacks_rate_limit_rejected_count_total{bucket=…}`.
        counter(
          [:stacks, :rate_limit, :rejected, :count, :total],
          event_name: [:stacks, :rate_limit, :rejected],
          description: "Requests rejected with 429 by the RateLimiter plug, by bucket.",
          tags: [:bucket]
        ),

        # ── Moderation funnel step counters (Issue #228, US-4.1 §13) ──
        # Per-step observability of the moderation pipeline so the funnel
        # can be broken down by outcome rather than collapsed into the
        # coarse `stacks_upload_terminal_count_total`. Every tag below is a
        # whitelisted atom set at the emit site — no ISBN/title/PII.
        #
        # Step 1 — classification. `outcome` ∈ book|not_a_book|ambiguous|
        # unknown. Exported as `stacks_moderation_classification_count_total`.
        counter(
          [:stacks, :moderation, :classification, :count, :total],
          event_name: [:stacks, :moderation, :classification],
          description: "Moderation step-1 classification outcomes.",
          tags: [:outcome]
        ),

        # Step 2 — ISBN resolution, one per candidate. `outcome` ∈
        # resolved|isbn_not_found|low_confidence|invalid_book|store_failed|
        # task_exit|other. Exported as
        # `stacks_moderation_isbn_resolution_count_total`.
        counter(
          [:stacks, :moderation, :isbn_resolution, :count, :total],
          event_name: [:stacks, :moderation, :isbn_resolution],
          description: "Moderation step-2 ISBN-resolution outcomes, per candidate.",
          tags: [:outcome]
        ),

        # Age-gate tiering. Repointed (Issue #118): the automatic
        # subject→BISAC classifier was removed, so this now fires from
        # `Stacks.Books.set_visibility_tier/3` when a PERSON sets the tier.
        # `tier` ∈ public|age_gated, `source` ∈ user|owner. Exported as
        # `stacks_moderation_tiering_count_total`.
        counter(
          [:stacks, :moderation, :tiering, :count, :total],
          event_name: [:stacks, :moderation, :tiering],
          description:
            "Visibility-tier changes (public vs age_gated) set by a user or the owner.",
          tags: [:tier, :source]
        ),

        # Compound-title expansion — one per `" OR "` split. Exported as
        # `stacks_moderation_compound_expansion_count_total`.
        counter(
          [:stacks, :moderation, :compound_expansion, :count, :total],
          event_name: [:stacks, :moderation, :compound_expansion],
          description: "Compound-title (' OR ') candidate expansions."
        ),

        # ── Age-gate operational counters (Issue #228, US-4.2 §13) ────
        # Age-gate enforcement decisions for age-gated books only.
        # `outcome` ∈ blocked|passed. Exported as
        # `stacks_age_gate_enforce_count_total`.
        counter(
          [:stacks, :age_gate, :enforce, :count, :total],
          event_name: [:stacks, :age_gate, :enforce],
          description: "Age-gate enforcement decisions on age-gated books (blocked vs passed).",
          tags: [:outcome]
        ),

        # Provider-sourced age verifications recorded (ADR-020). `outcome` ∈
        # success|error. Repointed from the removed self-declared endpoint to
        # Stacks.AgeVerification.record_verification/3. Exported as
        # `stacks_age_verification_count_total`.
        counter(
          [:stacks, :age_verification, :count, :total],
          event_name: [:stacks, :age_verification],
          description: "Provider-sourced age verifications recorded (success vs error).",
          tags: [:outcome]
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
        ),

        # ── GDPR: data-export job outcomes (Issue #121, Phase 4) ──────
        # One event per DataExportJob. `result` is `:ok` | `:error`.
        # Exported as `stacks_gdpr_export_count_total`.
        counter(
          [:stacks, :gdpr, :export, :count, :total],
          event_name: [:stacks, :gdpr, :export],
          description: "GDPR data-export job outcomes (right to portability).",
          tags: [:result]
        ),

        # ── GDPR: account-deletion job outcomes + failed step ─────────
        # One event per AccountDeletionJob. On failure, `failed_step` carries
        # the Ecto.Multi step id where the erasure broke (e.g. `:delete_user`),
        # so a broken right-to-erasure is not just alertable but diagnosable.
        # Exported as `stacks_gdpr_deletion_count_total`.
        counter(
          [:stacks, :gdpr, :deletion, :count, :total],
          event_name: [:stacks, :gdpr, :deletion],
          description: "GDPR account-deletion job outcomes (right to erasure).",
          tags: [:result, :failed_step]
        ),

        # ── GDPR: consent grant / revoke counters ─────────────────────
        # One event per successful consent transition. Exported as
        # `stacks_gdpr_consent_grant_count_total` and
        # `stacks_gdpr_consent_revoke_count_total`.
        counter(
          [:stacks, :gdpr, :consent, :grant, :count, :total],
          event_name: [:stacks, :gdpr, :consent, :grant],
          description: "Analytics-consent grants recorded with timestamps.",
          tags: [:feature]
        ),
        counter(
          [:stacks, :gdpr, :consent, :revoke, :count, :total],
          event_name: [:stacks, :gdpr, :consent, :revoke],
          description: "Analytics-consent revocations.",
          tags: [:feature]
        ),

        # ── GDPR: image-retention counts (30-day deletion promise) ────
        # These use `sum` over the `:count` measurement because each event
        # carries the batch size (N images purged this run), not a single
        # occurrence. `:expired` is tagged by `:reason` ("expired" for the
        # natural-TTL sweep, "stuck" for the safety-net sweep) to give the
        # image.expired-by-reason breakdown. Exported as
        # `stacks_gdpr_image_{expired,stuck,orphan}_count_total`.
        sum(
          [:stacks, :gdpr, :image, :expired, :count, :total],
          event_name: [:stacks, :gdpr, :image, :expired],
          measurement: :count,
          # NOTE: reason="stuck" MIRRORS the :stuck metric — query :expired split
          # by :reason; never sum :expired + :stuck (double-counts stuck).
          # See Stacks.GDPR.ImageRetention.cleanup_stuck_images/0.
          description:
            "Images purged past their 30-day deadline, BY :reason (expired=TTL sweep, stuck=safety-net). Query split by reason; do not sum with the stuck metric.",
          tags: [:reason]
        ),
        sum(
          [:stacks, :gdpr, :image, :stuck, :count, :total],
          event_name: [:stacks, :gdpr, :image, :stuck],
          measurement: :count,
          description: "Images cleaned by the stuck-pending safety net.",
          tags: [:reason]
        ),
        sum(
          [:stacks, :gdpr, :image, :orphan, :count, :total],
          event_name: [:stacks, :gdpr, :image, :orphan],
          measurement: :count,
          description: "Images past expiry still in the DB (retention-gap alarm)."
        ),

        # ── GDPR: audit-log write throughput ──────────────────────────
        # One event per successful audit_log insert. Watching this rate
        # surfaces both throughput anomalies and silent audit-logging stalls.
        # Exported as `stacks_gdpr_audit_write_count_total`.
        counter(
          [:stacks, :gdpr, :audit, :write, :count, :total],
          event_name: [:stacks, :gdpr, :audit, :write],
          description: "Audit-log write throughput (one per successful insert).",
          tags: [:action, :resource_type]
        )
      ])
    ]
  end
end
