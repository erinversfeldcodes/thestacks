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
        # These five were declared in `CoreWeb.Telemetry.metrics/0`, which has NO
        # reporter — its supervisor's only child is the poller. So every one of
        # them was emitted, counted by nothing, and on no dashboard: the prose
        # written for them described series that did not exist. The plugin is
        # where a metric becomes observable, so they are declared here too.
        # ⛔ THE ROLLOUT'S DECIDING INSTRUMENT, not an observability nicety. The
        # bearer transport is deleted when this counter's `bearer` series reads
        # zero for a release — so without the series the deletion is a guess,
        # and this repository has a recorded dual path that became permanent
        # because nothing measured which half was live.
        #
        # ⚠️ Declared HERE as well as emitted, which is the lesson the comment
        # above this group records: five metrics were emitted, counted by
        # nothing, and on no dashboard. The plugin is where a metric becomes
        # observable.
        # ⛔ THE COMPANION TO THE TRANSPORT SERIES, and a separate series rather
        # than a tag on it. The transport counter answers "which transport is
        # carrying sessions" — the bearer-DELETION question — and a present but
        # undecodable cookie falls through to bearer, so it is counted `:bearer`
        # exactly like no cookie at all. During a migration that is the expected
        # initial reading, which means a SYSTEMIC cookie failure (key rotation,
        # or cookies silently not being sent) looks like "the rollout has not
        # started". This series is what says otherwise.
        # ⛔ THE MEASUREMENT A PENDING DECISION TURNS ON, not observability for
        # its own sake. `SameSite=Lax` is the CSRF defence until a double-submit
        # token exists, and it blocks the cookie on every cross-site
        # state-changing method; its one hole (top-level GET navigation) has no
        # state-changing target here. So the residual threat a token would close
        # is principally clients that IGNORE SameSite — and whether that is
        # worth a 77-call-site refactor plus an enforcement step that can reject
        # writes is a measurement rather than a judgement.
        #
        # ⚠️ Nothing recorded an inbound user agent before this, so the question
        # was unanswerable from existing data. The string is classified into
        # three atoms and discarded — never stored.
        counter(
          [:stacks, :auth, :samesite_support, :count, :total],
          event_name: [:stacks, :auth, :samesite_support],
          description:
            "Authenticated requests by whether the client enforces the SameSite cookie attribute (enforces/does_not_enforce/unknown). Counted on AUTHENTICATED requests only: anonymous traffic has no session to forge, and including it dilutes the figure in the direction of looking riskier than it is. A large unknown bucket is a finding about the classifier rather than an answer about the traffic — it never defaults to enforces.",
          tags: [:enforces]
        ),
        counter(
          [:stacks, :auth, :session_cookie_rejected, :count, :total],
          event_name: [:stacks, :auth, :session_cookie_rejected],
          description:
            "Requests that presented a session cookie which failed to verify, by bounded reason. A present-but-unusable cookie falls through to the bearer path and is counted as bearer by the transport series, so without this a systemic cookie failure is indistinguishable from the rollout not having started. Non-zero and rising means cookies are being issued and refused — check key rotation and whether Secure cookies are reaching the server at all.",
          tags: [:reason]
        ),
        counter(
          [:stacks, :auth, :csrf_refused, :count, :total],
          event_name: [:stacks, :auth, :csrf_refused],
          description:
            "State-changing requests REFUSED for failing the double-submit check, by bounded reason (absent_header/absent_cookie/mismatched). Separate from the proof counter because that one counts what arrived and this one counts what was rejected: a rise here is the only signal that enforcement is turning real traffic away, and the reason says whose bug it is — absent_header a client, absent_cookie a server or cookie-attribute problem, mismatched the only one consistent with an attack. Expected to sit at zero; non-zero and rising after a release means a client path was missed.",
          tags: [:reason]
        ),
        counter(
          [:stacks, :auth, :csrf_proof, :count, :total],
          event_name: [:stacks, :auth, :csrf_proof],
          description:
            "State-changing requests by whether they carried a usable double-submit proof (proven/absent_header/absent_cookie/mismatched), with safe methods counted as `safe` so the series has a denominator. Emitted BEFORE any enforcement exists, so the decision to start rejecting is a reading rather than a judgement: enforcement goes on when absent_header holds at zero over real traffic. The two absent outcomes are separate because they are different bugs — absent_header is a client that did not send the proof, absent_cookie a browser that never received one. SCOPE: the `:api` pipeline only, which is 83 of 93 state-changing routes; the 4 partner_auth routes carry an Argon2 key and no cookie, and the 6 /api/test/* helpers are not reachable in production. A zero here is a statement about those 83, not about all writes.",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :auth, :session_transport, :count, :total],
          event_name: [:stacks, :auth, :session_transport],
          description:
            "Authenticated requests by the transport that carried the session: cookie, bearer, or untagged. Counts only requests that authenticated — an unauthenticated request offers a transport too, and counting those would let the bearer series read zero on a stream of failures. `bearer` is now a POSITIVE detection of an Authorization header, not a default: it previously caught every request the cookie plug did not tag, so a deployed reading of 187 could not distinguish a bearer token from some other route to authentication. `untagged` is that residue, and should be zero — a non-zero value means something authenticates by a path nobody has described. The bearer path is deleted when its series holds at zero for a release, which a stack that scales to zero cannot show.",
          tags: [:transport]
        ),
        counter(
          [:stacks, :auth, :password_reset, :count, :total],
          event_name: [:stacks, :auth, :password_reset],
          description:
            "Password reset requests by outcome. The rate_limited series is the count of readers who asked for a link and were silently sent nothing.",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :auth, :confirmation_resend, :count, :total],
          event_name: [:stacks, :auth, :confirmation_resend],
          description:
            "Confirmation resend requests by outcome (sent/rate_limited/no_account/already_confirmed/past_renewal_ceiling).",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :auth, :email_change, :count, :total],
          event_name: [:stacks, :auth, :email_change],
          description:
            "Email change flow by outcome. The reverted series is readers saying a change to their account was not theirs.",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :blog, :association, :count, :total],
          event_name: [:stacks, :blog, :association],
          description:
            "Blog book-association job outcomes — no_consent counts the posts whose text was never sent to an external model.",
          tags: [:outcome]
        ),
        last_value(
          [:stacks, :accounts, :email_change_lapsed, :degraded],
          event_name: [:stacks, :accounts, :email_change_lapsed],
          measurement: :degraded,
          description:
            "Accounts the daily sweep degraded because neither address answered an email change inside the grace window."
        ),
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
        # Emails handed to the provider, by template. Feeds the public cost
        # page's free-tier line, which is why it is a metric and not a query
        # over `oban_jobs`: job rows are pruned within a minute of completing.
        counter(
          [:stacks, :email, :delivered, :count, :total],
          event_name: [:stacks, :email, :delivered],
          measurement: :count,
          tags: [:template],
          description:
            "Transactional emails handed to the email provider, by template — the billable send count."
        ),
        counter(
          [:stacks, :upload, :terminal, :count, :total],
          event_name: [:stacks, :upload, :terminal],
          description: "Upload pipeline terminal outcomes (resolved/rejected/timeout).",
          tags: [:outcome]
        ),
        counter(
          [:stacks, :ai, :together_completion, :count, :total],
          event_name: [:stacks, :ai, :together_completion],
          description:
            "Successful Together AI chat completions — the billable unit the cost page counts."
        ),
        counter(
          [:stacks, :discovery, :brave_search, :count, :total],
          event_name: [:stacks, :discovery, :brave_search],
          description:
            "Successful Brave Search API queries — counted against the plan quota on the cost page."
        ),

        # ── Six families that fired into nothing ────────────────────────────
        # All six were declared ONLY in `CoreWeb.Telemetry.metrics/0`, whose
        # supervisor holds a `:telemetry_poller` and no reporter — so they were
        # emitted, covered by firing tests, and reached no store. A declaration
        # there is not observability; this plugin is where a metric becomes
        # visible, which is why they are declared here instead.
        #
        # ⚠️ Two of them meter MONEY: the spend the budget guard stops AI work
        # over, and the figures the cost page reports. A deletion of these as
        # "reporter-less telemetry" was proposed and would have made a
        # money-metering gap permanent — deleting a declaration is not the same
        # decision as deciding not to measure something.
        sum(
          [:stacks, :budget, :cost_recorded, :amount_micro_cents],
          event_name: [:stacks, :budget, :cost_recorded],
          measurement: :amount_micro_cents,
          description:
            "AI API spend recorded, in MICRO-CENTS (1 cent = 100,000) — the running total the budget guard compares against its daily and monthly limits. Micro-cents because one LLM call costs a fraction of a cent, so a cents-shaped series would round every call to zero; the money panel divides by 10,000,000 for dollars. ⚠️ The cost-page series beside this one IS in cents — the two money metrics differ in unit as well as in writer semantics.",
          tags: [:provider]
        ),
        # ⚠️ `last_value`, and fed from the LEDGER rather than from the event
        # stream above. The `sum` series accumulates what the application
        # emitted; these two report what the budget guard actually compared
        # against at decision time. They drift — a dropped event, a restart
        # mid-charge or a retention sweep moves one and not the other — and the
        # number a dashboard shows should be the one that refuses a request.
        last_value(
          [:stacks, :budget, :spend, :daily_cents],
          event_name: [:stacks, :budget, :spend],
          measurement: :daily_cents,
          description:
            "Today's recorded AI spend for this provider, in cents, as read from the durable ledger the daily limit is compared against.",
          tags: [:provider]
        ),
        last_value(
          [:stacks, :budget, :spend, :monthly_cents],
          event_name: [:stacks, :budget, :spend],
          measurement: :monthly_cents,
          description:
            "This month's recorded AI spend for this provider, in cents, as read from the durable ledger the monthly limit is compared against.",
          tags: [:provider]
        ),
        counter(
          [:stacks, :budget, :limit_exceeded, :count, :total],
          event_name: [:stacks, :budget, :limit_exceeded],
          description:
            "Budget refusals: an AI call the guard declined because the daily or monthly limit was already reached.",
          tags: [:provider, :type]
        ),
        # ⚠️ `last_value`, NOT `sum`, and the difference is the whole meaning of
        # this series.
        #
        # `Costs.upsert_cost/1` is idempotent: it replaces the row for
        # `{service, period_start, period_end}` and fires this event on every
        # success, replaces included. `RefreshCostsJob` runs daily and re-upserts
        # all ten items for the CURRENT MONTH, so each day's event carries the
        # month-to-date total, which already contains every earlier day's.
        #
        # Summed, the series would hold Σ(MTD₁ … MTD_N) — a figure that is not a
        # cost in any sense, and because `Telemetry.Metrics.Sum` renders as a
        # Prometheus counter it is monotonic and never resets at the month
        # boundary, so the error compounds forever instead of self-healing.
        #
        # The datum is a LEVEL (what the period has cost so far), not an event
        # (money moving), and `last_value` says exactly that. Read it with
        # `max by (service)`, never `rate()`.
        last_value(
          [:stacks, :costs, :recorded, :amount_cents],
          event_name: [:stacks, :costs, :recorded],
          measurement: :amount_cents,
          description:
            "Platform operating cost for the current billing period, in cents, by category and service — the figures the public cost page reports.",
          tags: [:category, :service]
        ),
        # The circuit breakers. These matter as much as the cost three: blow and
        # melt are what an operator reaches for when a dependency is failing,
        # and they were as invisible as the rest.
        counter(
          [:stacks, :fuse, :melt, :count, :total],
          event_name: [:stacks, :fuse, :melt],
          description:
            "A failure was counted against a circuit breaker, which is still closed. Rising melt with no blow is a dependency degrading rather than down.",
          tags: [:fuse_name]
        ),
        counter(
          [:stacks, :fuse, :blown, :count, :total],
          event_name: [:stacks, :fuse, :blown],
          description:
            "A circuit breaker opened: calls to that dependency now fail fast until it probes healthy again.",
          tags: [:fuse_name]
        ),
        counter(
          [:stacks, :crawler, :robots_fetch, :count, :total],
          event_name: [:stacks, :crawler, :robots_fetch],
          description:
            "robots.txt fetches served to crawlers. Carries no tags deliberately — a per-crawler label would be an unbounded user-agent string."
        ),

        # ── Vision request latency () ───────────────────────
        # Wall-clock for ONE Modal vision HTTP call. Emitted by
        # `Stacks.AI.Client.make_vision_request/2` on both the 200 and the
        # non-200 path — and, until now, consumed by nothing: the duration was
        # measured and never left the BEAM, so every timeout in the upload path
        # was sized from an estimate in a comment.
        #
        # `endpoint` ∈ is_book|analyze (the fixed set
        # `Stacks.AI.Client.endpoint_path/1` accepts — an unknown value raises
        # there, so this label cannot be widened by user input; it listed
        # extract_isbn and associate until those two operations were deleted on
        # 2026-10-15) and `status` is
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
        # The invite gate's own outcomes. Refusals were deliberately moved OFF the
        # registration counter above so they would not drown its signal — but no
        # reporter was declared for the event they moved to, so the launch gate went
        # from counted-but-noisy to not counted at all. `result` is bounded by
        # `invite_telemetry_label/1`: ok, required, invalid, expired, revoked,
        # exhausted, email_mismatch.
        counter(
          [:stacks, :auth, :invite, :count, :total],
          event_name: [:stacks, :auth, :invite],
          description: "Invite-gate outcomes at registration (closed-beta admission).",
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
            "Image bytes removed by the retention machinery, BY :reason (finished=the photograph discarded once identification had been terminal for the reader's retry window, ROW KEPT; expired=TTL sweep past the 30-day deadline; stuck=safety-net for wedged pending uploads; rowless=objects no uploaded_images row points at). Query split by reason; do not sum with the stuck metric. NOTE finished removes bytes only — the uploaded_images row survives, so this reason does NOT mean the image is gone. NOTE rowless is NOT the :orphan metric below — that one alarms on rows past expiry still in the DB, this one counts objects with no row at all.",
          tags: [:reason]
        ),
        sum(
          [:stacks, :gdpr, :image, :stuck, :count, :total],
          event_name: [:stacks, :gdpr, :image, :stuck],
          measurement: :count,
          description:
            "Images the never-finished safety net collected, BY :reason — stuck=a `pending` row whose identification job wedged or never ran; unredeemed=an `awaiting_upload` reservation whose bytes never arrived, so there was no job and nothing failed. Counted apart because a rise in abandoned uploads and a rise in broken ones are opposite problems with opposite fixes, and reporting both as \"stuck\" hides which is happening. NOTE `awaiting_upload` was invisible to this sweep until 2026-11-05 and such rows survived to their 30-day expiry, where they were counted as expired images — which is not what happened to them.",
          tags: [:reason]
        ),
        counter(
          [:stacks, :insights, :deanonymisation_unavailable, :count, :total],
          event_name: [:stacks, :insights, :deanonymisation_unavailable],
          description:
            "Times the de-anonymisation insight could not answer how identifiable a reader is, so the page showed \"could not compute\". NOT fatal: the rest of the payload renders. But this surface's whole failure character is that nobody becomes suspicious — it reported a non-answer to EVERY reader on every deployed stack for weeks while the suite was green, because the suite connects as a superuser that bypasses the policy that was refusing the query. A green suite says nothing about this number. ANY non-zero value is alert-worthy."
        ),
        last_value(
          [:stacks, :gdpr, :image, :standing],
          event_name: [:stacks, :gdpr, :image, :standing],
          measurement: :count,
          description:
            "STANDING population on each side of the uploads/ prefix, BY :population (rowless_objects = objects no uploaded_images row points at; rows_without_object = rows whose storage_path resolves to nothing). A gauge, not a collection counter: the sweep counters next to it emit zero both when they found nothing and when they never ran, which is how 4,234 row-less objects accumulated on production behind a clean dashboard. Either being non-zero is alert-worthy. NOTE a NULL storage_path is excluded from rows_without_object — since the finished-image sweep a row legitimately has no path.",
          tags: [:population]
        ),
        sum(
          [:stacks, :gdpr, :image, :orphan, :count, :total],
          event_name: [:stacks, :gdpr, :image, :orphan],
          measurement: :count,
          description: "Images past expiry still in the DB (retention-gap alarm)."
        ),
        # The export pair mirrors the image pair above. `:orphan` fires when a
        # complete copy of one reader's personal data outlived its deletion
        # deadline — the one number in that module that has to be visible, and
        # it was being emitted into nothing: declared at the call site, reported
        # by no plugin, so unobservable outside a log line.
        sum(
          [:stacks, :gdpr, :export, :expired, :count, :total],
          event_name: [:stacks, :gdpr, :export, :expired],
          measurement: :count,
          description: "Export archives purged past their deadline by the TTL sweep."
        ),
        sum(
          [:stacks, :gdpr, :export, :orphan, :count, :total],
          event_name: [:stacks, :gdpr, :export, :orphan],
          measurement: :count,
          description:
            "Export archives past expiry that could NOT be deleted — a copy of a reader's personal data outliving its deadline (retention-gap alarm)."
        ),
        # The third of this module's alarms, and the one that was still
        # log-only. An export object whose key carries no parseable deadline
        # can never be selected by the sweep, so it is not late — it is
        # permanent. That makes it the retention gap most worth a number.
        sum(
          [:stacks, :gdpr, :export, :undated, :count, :total],
          event_name: [:stacks, :gdpr, :export, :undated],
          measurement: :count,
          description:
            "Export archives whose key carries no deadline, so the TTL sweep can never select them — a permanent retention gap, not a late one."
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
        # These families are EMITTED by (profile-visibility changes,
        # ceiling rejections, the recap job, user block/unblock, and the ViewAs
        # owner-preview plug) but were never registered here, so they were absent
        # from `/internal/metrics` until. No new instrumentation is added —
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
        # ⚠️ Expected to stay at zero, and that is the point. The feed decorates
        # placements with map lookups where it once INNER JOINed, and a row
        # missing its book or owner is dropped to keep that rewrite
        # behaviour-preserving. The drop is believed unreachable (FK on book_id,
        # erasure removes a user's placements with the user) — registered so
        # that belief is measured rather than asserted. An emitted event with no
        # registered metric is a no-op, which would leave the counter looking
        # present and reporting nothing.
        sum(
          [:stacks, :social, :feed_row_undecorated, :total],
          event_name: [:stacks, :social, :feed_row_undecorated],
          measurement: :count,
          description:
            "Feed rows dropped for incomplete decoration (missing book title or owner name). Expected zero."
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
        # Instrumentation of the public discovery surfaces.
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
          description: "Public shelf-browse responses truncated by the public_shelf_cap."
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
