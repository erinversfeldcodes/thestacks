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

  # Buckets for the GDPR export/deletion job wall-time (Issue #238). These
  # jobs must finish well under the 30-day erasure/portability SLA; in
  # practice they complete in sub-second to low-minutes, so the buckets
  # span 100ms → 5min and a p95 over the distribution is the SLA-health
  # SLI. The measurement is already in milliseconds (the worker computes
  # elapsed via `System.monotonic_time`), so no unit conversion is applied.
  @gdpr_job_duration_buckets [
    100,
    250,
    500,
    1_000,
    5_000,
    10_000,
    30_000,
    60_000,
    120_000,
    300_000
  ]

  # Buckets for ONE Modal vision HTTP call (Issue #349). Chosen from the two
  # written claims this histogram exists to test, not from round numbers:
  #
  #   * The ESTIMATE. The `@route_duration_buckets` note above puts upload's
  #     real cost at "~3–8s (two sequential Modal vision calls + R2 upload +
  #     DB writes)". 3_000 and 8_000 are therefore bucket EDGES here, so the
  #     share of calls inside the claimed band is read straight off two bucket
  #     counts with no interpolation — the estimate becomes falsifiable rather
  #     than smoothed away.
  #   * The CEILING. `Stacks.AI.Client.receive_timeout_ms/0` is 210_000: the
  #     point the client hangs up. A slower call never reaches this event at
  #     all (it exits via `[:stacks, :vision, :request, :exception]`), so a top
  #     finite bucket AT the deadline makes `+Inf` structurally unreachable for
  #     `:stop` — which is exactly what the 2026-04-20 incident above was: a
  #     ceiling below the real tail left `+Inf` as the only bucket with counts,
  #     the p95 fell back to `2 × max_finite_bucket`, and reported a flat,
  #     false 10_000ms. A 20_000 ceiling here would reproduce that incident.
  #
  # `Core.PromEx.VisionLatencyTest` asserts the top bucket still equals the
  # client's timeout, so retuning that timeout (Issue #350) cannot silently
  # leave the histogram short of it.
  @vision_duration_buckets [
    100,
    250,
    500,
    1_000,
    2_000,
    3_000,
    5_000,
    8_000,
    15_000,
    30_000,
    60_000,
    120_000,
    210_000
  ]

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

        # ── Vision request latency (Issue #349) ───────────────────────
        # Wall-clock for ONE Modal vision HTTP call. Emitted by
        # `Stacks.AI.Client.make_vision_request/2` on both the 200 and the
        # non-200 path — and, until now, consumed by nothing: the duration was
        # measured and never left the BEAM, so every timeout in the upload path
        # was sized from an estimate in a comment (Issues #350, #351).
        #
        # `endpoint` ∈ is_book|extract_isbn|analyze|associate (the fixed set
        # `Stacks.AI.Client.endpoint_path/1` accepts — an unknown value raises
        # there, so this label cannot be widened by user input) and `status` is
        # the HTTP status integer. Both are bounded and neither is derived from
        # an upload: no ISBN, title, filename, image or user id reaches a label
        # (GDPR: telemetry is warehouse-adjacent). The `:exception` path carries
        # an unbounded `reason` term and is deliberately NOT registered here.
        #
        # Exported as
        # `stacks_vision_request_stop_duration_milliseconds_{bucket,sum,count}`.
        distribution(
          [:stacks, :vision, :request, :stop, :duration, :milliseconds],
          event_name: [:stacks, :vision, :request, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          description:
            "Per-call Modal vision request latency (ms), by endpoint and HTTP status — the distribution timeouts are sized from.",
          tags: [:endpoint, :status],
          reporter_options: [buckets: @vision_duration_buckets]
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

        # Trusted-client-IP resolution source (Issue #240, closes #176 gap) —
        # which path produced the per-IP rate-limit key. `source` is a bounded,
        # whitelisted atom (:trusted_proxy = Fly edge `fly-client-ip` header |
        # :remote_ip = socket peer fallback | :fallback = neither resolvable) set
        # in RateLimiter.get_ip/1. NEVER the IP value itself (GDPR: an IP is
        # personal data + would explode cardinality — only the source-kind is
        # tagged). A rise in :fallback, or :remote_ip on a Fly deploy, means the
        # proxy/IP chain is misconfigured (rate-limit bypass/mis-attribution
        # risk). Exported as `stacks_rate_limit_client_ip_count_total{source=…}`.
        counter(
          [:stacks, :rate_limit, :client_ip, :count, :total],
          event_name: [:stacks, :rate_limit, :client_ip],
          description:
            "Trusted-client-IP resolution source for rate-limit keying (trusted_proxy|remote_ip|fallback); no IP value tagged.",
          tags: [:source]
        ),

        # ── Auth/session security counters (Issue #237, epic #231) ────
        # Refresh-token REUSE detected — fires from Accounts.check_token_family/3
        # on the family-burn branch when a rotated/superseded refresh token is
        # replayed (token theft). No tags: any non-zero value is alert-worthy.
        # Exported as `stacks_auth_refresh_reuse_detected_count_total`.
        counter(
          [:stacks, :auth, :refresh, :reuse_detected, :count, :total],
          event_name: [:stacks, :auth, :refresh, :reuse_detected],
          description:
            "Replayed/rotated refresh tokens caught by the reuse gate (token-theft signal, alert-worthy)."
        ),

        # Session absolute-cap expiry — fires from AuthController.refresh/2 when a
        # session exceeds its 7-day window and is force-expired. `reason` is a
        # bounded whitelisted atom (:lifetime_cap). Exported as
        # `stacks_auth_session_expired_count_total{reason=…}`.
        counter(
          [:stacks, :auth, :session, :expired, :count, :total],
          event_name: [:stacks, :auth, :session, :expired],
          description: "Sessions force-expired by the absolute lifetime cap.",
          tags: [:reason]
        ),

        # MFA verification outcomes — fires from Stacks.MFA.verify_totp/2 and
        # verify_recovery_code/2. `outcome` is a bounded whitelisted atom
        # (:success | :failure). Exported as
        # `stacks_auth_mfa_verify_count_total{outcome=…}`.
        counter(
          [:stacks, :auth, :mfa, :verify, :count, :total],
          event_name: [:stacks, :auth, :mfa, :verify],
          description: "MFA verification attempts (TOTP + recovery code), by outcome.",
          tags: [:outcome]
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

        # Export job wall-time (Issue #238). Same event as the outcome counter,
        # reading the `:duration` measurement (job wall-time in ms the worker
        # computes via `System.monotonic_time`). p95 over this distribution is
        # the SLA-health SLI: exports must land well under the 30-day
        # portability promise. Exported as
        # `stacks_gdpr_export_duration_milliseconds_{bucket,sum,count}`.
        distribution(
          [:stacks, :gdpr, :export, :duration, :milliseconds],
          event_name: [:stacks, :gdpr, :export],
          measurement: :duration,
          description:
            "GDPR data-export job wall-time (ms), by result — p95 watches the 30-day SLA.",
          tags: [:result],
          reporter_options: [buckets: @gdpr_job_duration_buckets]
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

        # Deletion job wall-time (Issue #238). Same event as the outcome
        # counter, reading the `:duration` measurement (ms via
        # `System.monotonic_time`). Tagged by `:result` only (NOT `:failed_step`
        # — a per-step histogram would explode cardinality). p95 watches the
        # 30-day erasure SLA. Exported as
        # `stacks_gdpr_deletion_duration_milliseconds_{bucket,sum,count}`.
        distribution(
          [:stacks, :gdpr, :deletion, :duration, :milliseconds],
          event_name: [:stacks, :gdpr, :deletion],
          measurement: :duration,
          description:
            "GDPR account-deletion job wall-time (ms), by result — p95 watches the 30-day SLA.",
          tags: [:result],
          reporter_options: [buckets: @gdpr_job_duration_buckets]
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
        ),

        # ── GDPR: audit-log READ counter (Issue #238) ─────────────────
        # One event per user audit-log listing (`Stacks.Audit.list_for_user/2`)
        # so the "who looked at the audit log" side is observable, not just
        # writes. Deliberately UNTAGGED — no user-id/handle/IP reaches the
        # sink (GDPR: telemetry is warehouse-adjacent). Exported as
        # `stacks_gdpr_audit_read_count_total`.
        counter(
          [:stacks, :gdpr, :audit, :read, :count, :total],
          event_name: [:stacks, :gdpr, :audit, :read],
          description: "Audit-log read throughput (one per user audit-log listing; no PII tag)."
        ),

        # ── Visibility / Social / ViewAs counters (Issue #236) ────────
        # These families are EMITTED by #197 (profile-visibility changes,
        # ceiling rejections, the recap job, user block/unblock, and the ViewAs
        # owner-preview plug) but were never registered here, so they were absent
        # from `/internal/metrics` until #236. No new instrumentation is added —
        # this is registration only. Every tag below is a bounded, whitelisted
        # atom set at the emit site (never a handle/email/user-id — GDPR:
        # telemetry is warehouse-adjacent).
        #
        # Profile-visibility changes — `direction` ∈ tighten|loosen|same, from
        # Stacks.Visibility.emit_profile_visibility_change/2. Exported as
        # `stacks_visibility_profile_change_count_total{direction=…}`.
        counter(
          [:stacks, :visibility, :profile_change, :count, :total],
          event_name: [:stacks, :visibility, :profile_change],
          description: "Profile-visibility changes, by direction (tighten vs loosen vs same).",
          tags: [:direction]
        ),

        # Ceiling rejections — a mutation refused for exceeding its parent's
        # visibility ceiling. `resource_type` ∈ bookshelf|placement|post|other,
        # from Stacks.Visibility.emit_ceiling_rejection/1. Exported as
        # `stacks_visibility_ceiling_rejection_count_total{resource_type=…}`.
        counter(
          [:stacks, :visibility, :ceiling_rejection, :count, :total],
          event_name: [:stacks, :visibility, :ceiling_rejection],
          description: "Mutations rejected for exceeding their parent's visibility ceiling.",
          tags: [:resource_type]
        ),

        # Visibility-recap outcomes — one event per VisibilityRecapJob run.
        # `outcome` ∈ noop|capped|error. Telemetry.Metrics is one-metric-per-
        # measurement, so the occurrence counter (tagged by outcome) is declared
        # here and the three capped batch-sizes as `sum`s below. The recap emit
        # maps carry bookshelves_capped/placements_capped/posts_capped (NOT a
        # `count` key) — the Counter reporter increments per-event regardless of
        # measurement, so the outcome-tagged occurrence count is exact. Exported
        # as `stacks_visibility_recap_count_total{outcome=…}`.
        counter(
          [:stacks, :visibility, :recap, :count, :total],
          event_name: [:stacks, :visibility, :recap],
          description: "Visibility-recap job runs, by outcome (noop vs capped vs error).",
          tags: [:outcome]
        ),

        # Recap batch sizes — each recap event carries how many bookshelves /
        # placements / posts were capped down to the new profile ceiling. `sum`
        # over the respective measurement so the totals are observable. Exported
        # as `stacks_visibility_recap_{bookshelves,placements,posts}_capped_total`.
        sum(
          [:stacks, :visibility, :recap, :bookshelves_capped, :total],
          event_name: [:stacks, :visibility, :recap],
          measurement: :bookshelves_capped,
          description: "Bookshelves capped down by the visibility-recap job."
        ),
        sum(
          [:stacks, :visibility, :recap, :placements_capped, :total],
          event_name: [:stacks, :visibility, :recap],
          measurement: :placements_capped,
          description: "Placements capped down by the visibility-recap job."
        ),
        sum(
          [:stacks, :visibility, :recap, :posts_capped, :total],
          event_name: [:stacks, :visibility, :recap],
          measurement: :posts_capped,
          description: "Blog posts capped down by the visibility-recap job."
        ),

        # User block / unblock — untagged occurrence counters from
        # Stacks.Social.block_user/2 and unblock_user/2. Exported as
        # `stacks_social_block_count_total` and `stacks_social_unblock_count_total`.
        counter(
          [:stacks, :social, :block, :count, :total],
          event_name: [:stacks, :social, :block],
          description: "Users blocked (op.user_blocks inserts)."
        ),
        counter(
          [:stacks, :social, :unblock, :count, :total],
          event_name: [:stacks, :social, :unblock],
          description: "Users unblocked (op.user_blocks deletes)."
        ),

        # Block errors — a block insert that failed. `reason` ∈
        # already_blocked|invalid (bounded atom from block_error_reason/1).
        # Exported as `stacks_social_block_error_count_total{reason=…}`.
        counter(
          [:stacks, :social, :block_error, :count, :total],
          event_name: [:stacks, :social, :block_error],
          description: "Failed block attempts, by reason (already_blocked vs invalid).",
          tags: [:reason]
        ),

        # ViewAs usage — one per accepted `?view_as=` perspective in
        # StacksWeb.Plugs.ViewAsPlug. `perspective` ∈
        # unauthenticated|platform|specific_user (KIND only, never the raw uuid).
        # Exported as `stacks_view_as_usage_count_total{perspective=…}`.
        counter(
          [:stacks, :view_as, :usage, :count, :total],
          event_name: [:stacks, :view_as, :usage],
          description: "ViewAs owner-preview usage, by perspective kind.",
          tags: [:perspective]
        ),

        # ViewAs errors — a rejected ViewAs request. `reason` ∈
        # invalid_perspective|not_implemented|forbidden; `phase` ∈ parse|authorize.
        # Exported as `stacks_view_as_error_count_total{reason=…,phase=…}`.
        counter(
          [:stacks, :view_as, :error, :count, :total],
          event_name: [:stacks, :view_as, :error],
          description: "Rejected ViewAs requests, by reason and phase (parse vs authorize).",
          tags: [:reason, :phase]
        ),

        # ── Discovery / profiles / people-search counters (Issue #239) ────
        # Instrumentation of the public discovery surfaces (#210–#217, #221).
        # Every tag below is a bounded, whitelisted atom set at the emit site —
        # NEVER the search query string, a handle, a user-id, or an IP (those are
        # unbounded cardinality + PII; telemetry is warehouse-adjacent).
        #
        # People-search outcomes — one per `GET /api/search/users`. `outcome` ∈
        # hit|zero_result (zero_result = empty result list). The zero_result rate
        # is the search-quality signal. Exported as
        # `stacks_search_people_count_total{outcome=…}`.
        # (The emit also carries a `:results` numeric measurement — total matches
        # served — which a future `sum` family can consume; kept out of the
        # registered families for now to keep the panel↔family lock-step simple.)
        counter(
          [:stacks, :search, :people, :count, :total],
          event_name: [:stacks, :search, :people],
          description: "People-search requests, by outcome (hit vs zero_result).",
          tags: [:outcome]
        ),

        # Public-profile resolution outcomes — one per `/u/:handle` read.
        # `outcome` ∈ ok|not_found (not_found covers absent handle AND ghost/block
        # 404). The not_found rate is the broken-link / enumeration-probe signal.
        # Exported as `stacks_profile_view_count_total{outcome=…}`.
        counter(
          [:stacks, :profile, :view, :count, :total],
          event_name: [:stacks, :profile, :view],
          description: "Public-profile resolutions, by outcome (ok vs not_found/404).",
          tags: [:outcome]
        ),

        # Public-shelf pagination-cap hits — one per shelf-browse response the
        # #221 public_shelf_cap actually truncated. Untagged. Exported as
        # `stacks_shelf_browse_capped_count_total`.
        counter(
          [:stacks, :shelf, :browse_capped, :count, :total],
          event_name: [:stacks, :shelf, :browse_capped],
          description: "Public shelf-browse responses truncated by the public_shelf_cap (#221)."
        ),

        # Handle claims — one per successful profile update that set or changed
        # `:handle`. Untagged (the handle value never becomes a label). Exported
        # as `stacks_handle_claimed_count_total`.
        counter(
          [:stacks, :handle, :claimed, :count, :total],
          event_name: [:stacks, :handle, :claimed],
          description: "Public `/u/:handle` claims (handle set or changed on a profile update)."
        )
      ])
    ]
  end
end
