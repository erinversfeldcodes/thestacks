defmodule Core.PromEx.Plugins.Stacks do
  @moduledoc """
    PromEx plugin exporting the custom `[:stacks,...]` telemetry events —
    without it the `CoreWeb.Telemetry.metrics/0` entries have no reporter.
    The SLO gate (`scripts/check-slo-gate.sh`) reads `/internal/metrics` and
    expects exactly: `stacks_upload_terminal_count_total`,
    `stacks_router_dispatch_stop_duration_milliseconds_*`, and
    `stacks_fuse_state_state`. Metric paths end in `[:count,:total]` /
    `[:duration,:milliseconds]` because the Prometheus core reporter does
    not append suffixes — renaming a path here breaks the gate parser.
  """

  use PromEx.Plugin

  @route_duration_buckets [50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

  @dispatch_duration_buckets [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @query_duration_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

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
    300_000,
    330_000
  ]

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(:stacks_app_metrics, [
        counter(
          [:stacks, :events, :emitted, :count, :total],
          event_name: [:stacks, :events, :emitted],
          description: "Events appended to the op.event_log (pre-dispatch).",
          tags: [:event_type, :aggregate_type]
        ),
        counter(
          [:stacks, :events, :handler_invoked, :count, :total],
          event_name: [:stacks, :events, :handler_invoked],
          description: "Invocations of Stacks.Events handlers from SubscriberWorker.",
          tags: [:handler, :event_type]
        ),
        counter(
          [:stacks, :events, :handler_error, :count, :total],
          event_name: [:stacks, :events, :handler_error],
          description: "Handler errors (returned {:error, _} or raised).",
          tags: [:handler, :event_type]
        ),
        distribution(
          [:stacks, :events, :dispatch, :duration, :milliseconds],
          event_name: [:stacks, :events, :dispatch],
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Per-handler dispatch time in SubscriberWorker.",
          tags: [:handler, :event_type],
          reporter_options: [buckets: @dispatch_duration_buckets]
        ),
        distribution(
          [:stacks, :repo, :query, :duration, :milliseconds],
          event_name: [:stacks, :repo, :query, :duration],
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Per-query duration tagged by Oban worker, source table, and repo.",
          tags: [:worker, :source, :repo],
          reporter_options: [buckets: @query_duration_buckets]
        ),
        counter(
          [:stacks, :upload, :terminal, :count, :total],
          event_name: [:stacks, :upload, :terminal],
          description: "Upload pipeline terminal outcomes (resolved/rejected/timeout).",
          tags: [:outcome]
        ),

        # ── Vision request latency () ───────────────────────
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
        # (GDPR: telemetry is warehouse-adjacent).
        #
        # ⚠️ These quantiles are CONDITIONAL ON A RESPONSE ARRIVING. A call that
        # never gets one leaves via `[:stacks, :vision, :request, :exception]`
        # and contributes no duration, so this distribution structurally
        # under-reports its own tail. The counter below is the other half.
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
        counter(
          [:stacks, :vision, :request, :exception, :count, :total],
          event_name: [:stacks, :vision, :request, :exception],
          description:
            "Vision calls that produced no HTTP response, by endpoint and bounded failure class — where a client give-up becomes countable.",
          tags: [:endpoint, :reason_class]
        ),
        distribution(
          [:stacks, :router_dispatch, :stop, :duration, :milliseconds],
          event_name: [:stacks, :router_dispatch, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Phoenix route-dispatch latency tagged by route group.",
          tags: [:route_group],
          reporter_options: [buckets: @route_duration_buckets]
        ),

        # ── Auth refresh revoke-failure counter () ──────────
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
        counter(
          [:stacks, :auth, :registration, :count, :total],
          event_name: [:stacks, :auth, :registration],
          description: "User registration outcomes (right-to-account creation).",
          tags: [:result]
        ),
        counter(
          [:stacks, :auth, :jwt_issued, :count, :total],
          event_name: [:stacks, :auth, :jwt_issued],
          description: "Guardian JWTs issued, by issuance context (login vs refresh).",
          tags: [:context]
        ),
        counter(
          [:stacks, :auth, :login_failure, :count, :total],
          event_name: [:stacks, :auth, :login_failure],
          description: "Failed login attempts, broken down by failure type.",
          tags: [:type]
        ),
        counter(
          [:stacks, :rate_limit, :rejected, :count, :total],
          event_name: [:stacks, :rate_limit, :rejected],
          description: "Requests rejected with 429 by the RateLimiter plug, by bucket.",
          tags: [:bucket]
        ),
        counter(
          [:stacks, :rate_limit, :client_ip, :count, :total],
          event_name: [:stacks, :rate_limit, :client_ip],
          description:
            "Trusted-client-IP resolution source for rate-limit keying (trusted_proxy|remote_ip|fallback); no IP value tagged.",
          tags: [:source]
        ),
        counter(
          [:stacks, :auth, :refresh, :reuse_detected, :count, :total],
          event_name: [:stacks, :auth, :refresh, :reuse_detected],
          description:
            "Replayed/rotated refresh tokens caught by the reuse gate (token-theft signal, alert-worthy)."
        ),
        counter(
          [:stacks, :auth, :session, :expired, :count, :total],
          event_name: [:stacks, :auth, :session, :expired],
          description: "Sessions force-expired by the absolute lifetime cap.",
          tags: [:reason]
        ),
        counter(
          [:stacks, :auth, :mfa, :verify, :count, :total],
          event_name: [:stacks, :auth, :mfa, :verify],
          description: "MFA verification attempts (TOTP + recovery code), by outcome.",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :moderation, :classification, :count, :total],
          event_name: [:stacks, :moderation, :classification],
          description: "Moderation step-1 classification outcomes.",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :moderation, :isbn_resolution, :count, :total],
          event_name: [:stacks, :moderation, :isbn_resolution],
          description: "Moderation step-2 ISBN-resolution outcomes, per candidate.",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :moderation, :tiering, :count, :total],
          event_name: [:stacks, :moderation, :tiering],
          description:
            "Visibility-tier changes (public vs age_gated) set by a user or the owner.",
          tags: [:tier, :source]
        ),
        counter(
          [:stacks, :moderation, :compound_expansion, :count, :total],
          event_name: [:stacks, :moderation, :compound_expansion],
          description: "Compound-title (' OR ') candidate expansions."
        ),
        counter(
          [:stacks, :age_gate, :enforce, :count, :total],
          event_name: [:stacks, :age_gate, :enforce],
          description: "Age-gate enforcement decisions on age-gated books (blocked vs passed).",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :age_verification, :count, :total],
          event_name: [:stacks, :age_verification],
          description: "Provider-sourced age verifications recorded (success vs error).",
          tags: [:outcome]
        ),
        last_value(
          [:stacks, :fuse, :state, :state],
          event_name: [:stacks, :fuse, :state],
          measurement: :state,
          description: "Circuit breaker state (1 = healthy, 0 = blown).",
          tags: [:fuse_name]
        ),
        counter(
          [:stacks, :gdpr, :export, :count, :total],
          event_name: [:stacks, :gdpr, :export],
          description: "GDPR data-export job outcomes (right to portability).",
          tags: [:result]
        ),
        distribution(
          [:stacks, :gdpr, :export, :duration, :milliseconds],
          event_name: [:stacks, :gdpr, :export],
          measurement: :duration,
          description:
            "GDPR data-export job wall-time (ms), by result — p95 watches the 30-day SLA.",
          tags: [:result],
          reporter_options: [buckets: @gdpr_job_duration_buckets]
        ),
        counter(
          [:stacks, :gdpr, :deletion, :count, :total],
          event_name: [:stacks, :gdpr, :deletion],
          description: "GDPR account-deletion job outcomes (right to erasure).",
          tags: [:result, :failed_step]
        ),
        distribution(
          [:stacks, :gdpr, :deletion, :duration, :milliseconds],
          event_name: [:stacks, :gdpr, :deletion],
          measurement: :duration,
          description:
            "GDPR account-deletion job wall-time (ms), by result — p95 watches the 30-day SLA.",
          tags: [:result],
          reporter_options: [buckets: @gdpr_job_duration_buckets]
        ),
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
        sum(
          [:stacks, :gdpr, :image, :expired, :count, :total],
          event_name: [:stacks, :gdpr, :image, :expired],
          measurement: :count,
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
        counter(
          [:stacks, :gdpr, :audit, :write, :count, :total],
          event_name: [:stacks, :gdpr, :audit, :write],
          description: "Audit-log write throughput (one per successful insert).",
          tags: [:action, :resource_type]
        ),
        counter(
          [:stacks, :gdpr, :audit, :read, :count, :total],
          event_name: [:stacks, :gdpr, :audit, :read],
          description: "Audit-log read throughput (one per user audit-log listing; no PII tag)."
        ),

        # ── Visibility / Social / ViewAs counters () ────────
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
        counter(
          [:stacks, :visibility, :ceiling_rejection, :count, :total],
          event_name: [:stacks, :visibility, :ceiling_rejection],
          description: "Mutations rejected for exceeding their parent's visibility ceiling.",
          tags: [:resource_type]
        ),
        counter(
          [:stacks, :visibility, :recap, :count, :total],
          event_name: [:stacks, :visibility, :recap],
          description: "Visibility-recap job runs, by outcome (noop vs capped vs error).",
          tags: [:outcome]
        ),
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
        counter(
          [:stacks, :social, :block_error, :count, :total],
          event_name: [:stacks, :social, :block_error],
          description: "Failed block attempts, by reason (already_blocked vs invalid).",
          tags: [:reason]
        ),
        counter(
          [:stacks, :view_as, :usage, :count, :total],
          event_name: [:stacks, :view_as, :usage],
          description: "ViewAs owner-preview usage, by perspective kind.",
          tags: [:perspective]
        ),
        counter(
          [:stacks, :view_as, :error, :count, :total],
          event_name: [:stacks, :view_as, :error],
          description: "Rejected ViewAs requests, by reason and phase (parse vs authorize).",
          tags: [:reason, :phase]
        ),

        # ── Discovery / profiles / people-search counters () ────
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
        counter(
          [:stacks, :profile, :view, :count, :total],
          event_name: [:stacks, :profile, :view],
          description: "Public-profile resolutions, by outcome (ok vs not_found/404).",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :shelf, :browse_capped, :count, :total],
          event_name: [:stacks, :shelf, :browse_capped],
          description: "Public shelf-browse responses truncated by the public_shelf_cap (#221)."
        ),
        counter(
          [:stacks, :handle, :claimed, :count, :total],
          event_name: [:stacks, :handle, :claimed],
          description: "Public `/u/:handle` claims (handle set or changed on a profile update)."
        )
      ])
    ]
  end
end
