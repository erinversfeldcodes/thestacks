import Config

# ── Test env: config/test.exs is self-contained, no env vars needed ──────────
if config_env() == :test do
  # Nothing here — tests use hardcoded values and mock backends from config/test.exs.
  # This early return prevents .env vars from overriding test configuration.
else
  # ── Secrets (required in dev + prod) ───────────────────────────────────────

  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise "environment variable CLOAK_KEY is missing. Generate with: :crypto.strong_rand_bytes(32) |> Base.encode64()"

  config :core, Stacks.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
      }
    ]

  vision_hmac_secret =
    System.get_env("VISION_HMAC_SECRET") ||
      raise "environment variable VISION_HMAC_SECRET is missing."

  if byte_size(String.trim(vision_hmac_secret)) < 16 do
    raise "VISION_HMAC_SECRET must be at least 16 characters."
  end

  config :core, :vision_hmac_secret, vision_hmac_secret

  if guardian_secret = System.get_env("GUARDIAN_SECRET_KEY") do
    config :core, Stacks.Accounts.Guardian, issuer: "stacks", secret_key: guardian_secret
  end

  # ── Optional service config (dev + prod) ─────────────────────────────────

  if google_books_key = System.get_env("GOOGLE_BOOKS_API_KEY") do
    config :core, :google_books_api_key, google_books_key
  end

  if brave_key = System.get_env("BRAVE_SEARCH_API_KEY") do
    config :core, :brave_search_api_key, brave_key
  end

  if together_key = System.get_env("VISION_TOGETHER_API_KEY") do
    config :core, :vision_together_api_key, together_key
  end

  # Public transparency live signals (#241 / ADR-019). The Live section of
  # /api/transparency/metrics reads the self-hosted VictoriaMetrics
  # (ADR-021 / #255) at `<base>/api/v1/query` — same 6PN VM the metrics pusher
  # writes to, so no token and no org slug are needed (the retired Fly
  # managed-Prometheus client required both as Fly secrets).
  # Defaults to the push target; when neither is set the live section degrades to
  # `:unavailable` — it must NOT break boot. Curated allowlist reads only.
  metrics_query_url =
    System.get_env("STACKS_METRICS_QUERY_URL") || System.get_env("STACKS_METRICS_PUSH_URL")

  config :core, :metrics_query_url, metrics_query_url

  if auth_limit = System.get_env("RATE_LIMIT_AUTH") do
    config :core, :rate_limit_auth, String.to_integer(auth_limit)
  end

  if public_limit = System.get_env("RATE_LIMIT_PUBLIC") do
    config :core, :rate_limit_public, String.to_integer(public_limit)
  end

  # Test-helper bucket (Issue #124) — prod default is a tight 10/60s/IP; preview
  # raises it so the parallel E2E suite isn't throttled. Never set in prod (the
  # helpers themselves are prod-disabled).
  if e2e_helper_limit = System.get_env("RATE_LIMIT_E2E_HELPER") do
    config :core, :rate_limit_e2e_helper, String.to_integer(e2e_helper_limit)
  end

  if r2_account_id = System.get_env("R2_ACCOUNT_ID") do
    config :core, :storage, Stacks.Storage.R2

    config :ex_aws,
      access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY"),
      region: "auto"

    config :ex_aws, :s3,
      scheme: "https://",
      host: "#{r2_account_id}.r2.cloudflarestorage.com",
      region: "auto"

    config :core, :r2_bucket, System.get_env("R2_BUCKET_NAME", "stacks-images")
  end

  if scraper_hmac = System.get_env("SCRAPER_HMAC_SECRET") do
    config :core, :scraper_hmac_secret, scraper_hmac
  end

  if scraper_url = System.get_env("SCRAPER_SERVICE_URL") do
    config :core, :scraper_service_url, scraper_url
  end

  if searxng_url = System.get_env("SEARXNG_URL") do
    config :core, :searxng_url, searxng_url
  end

  # Enable the circuit breaker smoke endpoint on preview/dev deployments.
  # Never set SMOKE_TESTS_ENABLED in production — the endpoint blows all fuses
  # and waits 30s for probe-driven recovery. Default: false.
  if System.get_env("SMOKE_TESTS_ENABLED") in ~w(true 1) do
    config :core, :smoke_tests_enabled, true
  end

  # Age-gating kill-switch (ADR-020). Shipped dark: default OFF in production, so
  # all three enforcement points (AgeGate.enforce/2, Books.maybe_exclude_age_gated/2,
  # Visibility.check_age_gate/3) are no-ops and age-gated books behave as public.
  # Flip AGE_GATING_ENABLED=true — once a real verification provider is integrated —
  # to activate the already-validated behaviour with no code change. Read only
  # through Stacks.FeatureFlags.age_gating_enabled?/0.
  config :core, :age_gating_enabled, System.get_env("AGE_GATING_ENABLED") == "true"

  # METRICS_SCRAPE_TOKEN guards /internal/metrics. StacksWeb.Plugs.MetricsAuth
  # requires a matching `Authorization: Bearer <token>` from public callers —
  # which, post-ADR-021, is the only way in: the store is fed by push
  # (STACKS_METRICS_PUSH_URL below) and the retired Fly managed-Prometheus
  # scrape is gone (#323), leaving the plug's 6PN bypass without a caller.
  # Unset = no public caller (the SLO gate, scripts/check-slo-gate.sh) can
  # read the exposition. Required in prod; CI sets it via `fly secrets`.
  config :core, :metrics_scrape_token, System.get_env("METRICS_SCRAPE_TOKEN")

  # Push PromEx metrics to self-hosted VictoriaMetrics (ADR-021 / #253). When set
  # (e.g. `http://thestacks-victoriametrics.internal:8428`), Core.PromEx.MetricsPusher
  # POSTs the exposition to VM's import endpoint over 6PN. Unset → pusher stays a
  # no-op (init → :ignore). Replaces Fly's managed-Prometheus scrape (#248).
  config :core, :metrics_push_url, System.get_env("STACKS_METRICS_PUSH_URL")

  # Optional Grafana dashboard upload (Issue #232). When both GRAFANA_HOST
  # and GRAFANA_AUTH_TOKEN are set (as Fly secrets pointing at the org's
  # fly-metrics.net Grafana), PromEx uploads the dashboards-as-code from
  # `Core.PromEx.dashboards/0` at boot. When either is unset, PromEx defaults
  # to `grafana: :disabled` — a no-op that must NOT break boot (mirrors the
  # log-shipper guard). Dashboards can also be imported once by hand; see
  # docs/runbooks/metrics-stack.md.
  grafana_host = System.get_env("GRAFANA_HOST")
  grafana_token = System.get_env("GRAFANA_AUTH_TOKEN")

  if grafana_host && grafana_token && grafana_host != "" && grafana_token != "" do
    config :core, Core.PromEx,
      grafana: [
        host: grafana_host,
        auth_token: grafana_token,
        upload_dashboards_on_start: true
      ]
  end
end

# Real transactional email via Resend can be opted into in ANY environment
# (e.g. local testing of the actual send path) by setting EMAIL_PROVIDER=resend
# + RESEND_API_KEY — independent of the prod/PHX_SERVER gate below. Off by
# default: dev uses the in-memory Local mailbox and test uses the Test adapter.
#
# In :test, default to the hermetic Test adapter (config/test.exs) even when
# EMAIL_PROVIDER=resend + RESEND_API_KEY are present — `just` loads `.env`
# (dotenv-load) so both are set on every `just run mix test`. Opt into a real
# Resend send only when a real recipient is explicitly provided via
# TEST_EMAIL_RECIPIENT — see issue #258. Non-test envs are unchanged.
# An env var counts only when non-nil AND non-empty — an exported-but-empty
# `TEST_EMAIL_RECIPIENT=` (or empty EMAIL_PROVIDER/RESEND_API_KEY) must read as
# unset, so it can't silently wire the real adapter with the factory
# example.com default (→ Resend 422). Mirrors the "" -> unset semantics of the
# test's recipient_opts/0 helper so the guard and the test agree.
present? = fn name -> (System.get_env(name) || "") != "" end

resend_configured? = System.get_env("EMAIL_PROVIDER") == "resend" && present?.("RESEND_API_KEY")

real_send? =
  resend_configured? && (config_env() != :test || present?.("TEST_EMAIL_RECIPIENT"))

if real_send? do
  config :core, Stacks.Email.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY")
end

# ── Prod-only (release) ───────────────────────────────────────────────────────
# This block has two layers:
#
#   1. Migrate-essential config (DATABASE_URL + Repo + ObanRepo) runs
#      unconditionally — both `mix ecto.migrate` from the GHA runner AND
#      the running prod container need it.
#   2. Server-only config (VISION_SERVICE_URL, SECRET_KEY_BASE, endpoint
#      binding, mailer, clustering, etc.) runs only when PHX_SERVER is
#      set. Dockerfile.core sets `ENV PHX_SERVER=true` (line 92) so the
#      running container always validates these. `mix ecto.migrate`
#      from the GHA runner does NOT set PHX_SERVER, so server-only
#      validations skip — unblocking Phase 4 of #137 (runner-side
#      migrate before image cutover) without weakening prod boot
#      validation.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # POOL_SIZE default: 40. Evolution:
  #   10 → 20: initial bump after db_pool_queue_p95_ms=89ms
  #   20 → 30: split Oban off into Core.ObanRepo (OBAN_POOL_SIZE=50)
  #   30 → 40: counter-intuitive but necessary. Splitting Oban at 50
  #     workers meant more concurrent background jobs, each of which
  #     runs its BUSINESS-LOGIC queries through Core.Repo (e.g.
  #     IdentifyBookJob inserts books via Books.store_book →
  #     Core.Repo, NOT Core.ObanRepo). So the split relieved
  #     pressure on Oban's INFRASTRUCTURE queue state but worsened
  #     Core.Repo contention. db_pool_queue_p95_ms went 78ms → 169ms
  #     after the split. The fix: bigger Core.Repo pool + smaller
  #     Oban pool (25 is still well above the infra-queries need).
  #
  # Total connections per machine: 40 (Core.Repo) + 50 (Core.ObanRepo)
  # = 90. With 2 machines: 180 — under Neon's 200 ceiling. (The prior
  # ObanRepo=80 put 2 machines at 240, OVER the ceiling; see the
  # OBAN_POOL_SIZE note below.)
  config :core, Core.Repo,
    url: database_url,
    ssl: true,
    parameters: [search_path: "public,op"],
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "40"),
    socket_options: maybe_ipv6

  # Dedicated repo for Oban. Having background workers share
  # Core.Repo meant a burst of enqueued jobs could starve HTTP
  # request handlers of DB connections — exactly the contention
  # profile db_pool_queue_p95_ms measures. A separate repo with its
  # own pool decouples the two: HTTP keeps its 30 connections for
  # user-facing traffic; Oban workers compete only among themselves
  # on their own pool.
  #
  # OBAN_POOL_SIZE default: 50. Evolution:
  #   15: initial pool-split default (too low — Oban's own GROUP BY
  #     poll waited ~800ms for a connection)
  #   50→25→80: earlier attempts sized the pool as "one connection per
  #     concurrent worker" — but that conflates the two repos. A worker's
  #     BUSINESS-LOGIC queries go through Core.Repo; Core.ObanRepo only
  #     serves Oban's INFRASTRUCTURE (job fetch, state-transition acks,
  #     pruner, Stager poll, PromEx poll). A worker does NOT hold an
  #     ObanRepo connection for its run — only briefly at fetch and ack.
  #     So the pool needs to cover peak concurrent acks + infra polls, not
  #     one-per-worker. The `80` was over-sized to feed `:vision`=60 under
  #     that misconception, which pushed 2-machine totals (40+80)×2 = 240
  #     OVER Neon's 200 ceiling.
  #   50: `:vision` right-sized to 20 (Modal-bound; see config.exs). Peak
  #     ObanRepo demand ≈ concurrent acks across all queues (≤ the new total
  #     concurrency of 59, realistically far fewer at any instant) + ~15
  #     infra connections. 50 gives comfortable headroom while dropping the
  #     per-machine total to 40+50 = 90 → 180 at 2 machines, back UNDER
  #     Neon's 200 ceiling. Can likely go to ~40 once validated at the gate.
  #
  # Both repos point at the same Postgres database, so Oban still
  # sees the same event_log, same op.* tables, same job state — just
  # through a separate connection set. See Core.Repo POOL_SIZE
  # comment above for the total-connections budget.
  config :core, Core.ObanRepo,
    url: database_url,
    ssl: true,
    parameters: [search_path: "public,op"],
    pool_size: String.to_integer(System.get_env("OBAN_POOL_SIZE") || "80"),
    socket_options: maybe_ipv6

  # ── Server-only config — gated on PHX_SERVER ────────────────────────────────
  # Dockerfile.core sets ENV PHX_SERVER=true so the running container hits
  # this branch and validates everything below. `mix ecto.migrate` from the
  # GHA runner doesn't set PHX_SERVER, so it skips these checks and migrates
  # cleanly without needing service URLs / endpoint config it never uses.
  if System.get_env("PHX_SERVER") do
    vision_service_url =
      System.get_env("VISION_SERVICE_URL") ||
        raise "environment variable VISION_SERVICE_URL is missing."

    config :core, :vision_service_url, vision_service_url

    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "readinginthestacks.com"
    port = String.to_integer(System.get_env("PORT") || "4000")

    config :core, CoreWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: port
      ],
      secret_key_base: secret_key_base

    config :core, upload_dir: "/tmp/uploads"

    if System.get_env("EMAIL_PROVIDER") == "resend" do
      config :core, Stacks.Email.Mailer,
        adapter: Swoosh.Adapters.Resend,
        api_key: System.fetch_env!("RESEND_API_KEY")
    end

    # Override the transactional-email sender without a redeploy. Defaults to
    # `onboarding@resend.dev` (config.exs); set EMAIL_FROM to a verified address
    # (e.g. noreply@thestacks.app) once the Resend domain is verified.
    if from = System.get_env("EMAIL_FROM") do
      config :core, :email_from, {"The Stacks", from}
    end

    # Erlang clustering on Fly.io — only active when FLY_APP_NAME is set.
    # rel/env.sh.eex sets RELEASE_DISTRIBUTION=name and RELEASE_NODE=<app>@<ipv6>.
    # Phoenix.PubSub's pg adapter broadcasts across all connected nodes automatically
    # once libcluster connects them, so SSE streams on any machine receive events
    # from Oban jobs on any other machine.
    if fly_app = System.get_env("FLY_APP_NAME") do
      config :libcluster,
        topologies: [
          fly: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: "#{fly_app}.internal",
              node_basename: fly_app
            ]
          ]
        ]
    end

    # `:sse_max_timeout_ms` is deliberately NOT set here. It used to be pinned at
    # 360_000 — a number chosen to be "about how long a Modal cold start plus
    # retries takes", maintained by hand alongside the worker's retry schedule
    # and wrong whenever either moved. `StacksWeb.UploadController` now derives
    # the deadline from `Stacks.Workers.IdentifyBookJob.worst_case_lifetime_ms/0`,
    # so the reader's give-up time follows the job's death by construction.
    # Setting the key in a deployed environment reinstates the divergence.
  end
end
