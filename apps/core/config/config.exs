import Config

# ── Overridden framework defaults ──────────────────────────────────────────────
# These settings change Ecto/Phoenix defaults globally. Reviewers and agents
# should be aware of them — they affect generated code and query behaviour.
#
#   generators:
#     binary_id: true        → all generated schemas use UUID primary keys
#     timestamp_type          → :utc_datetime_usec (microsecond precision)
#
#   migration_timestamps:
#     type: :utc_datetime_usec → all timestamps() calls use microsecond precision
#     inserted_at: :created_at → ALL timestamps() calls produce a column named
#                                "created_at", NOT the Ecto default "inserted_at".
#                                This applies to every migration in the project.
#
#   migration_primary_key (in Repo.init/2):
#     type: :binary_id       → all migrations default to UUID primary keys
# ──────────────────────────────────────────────────────────────────────────────

config :core,
  # Core.ObanRepo is a dedicated pool for Oban, pointed at the same
  # database as Core.Repo. See apps/core/lib/core/oban_repo.ex for
  # the rationale. Listed in ecto_repos so migrations apply to it
  # too — though in practice both repos target the same DB so either
  # one running migrations is sufficient. Keeping both for clarity.
  ecto_repos: [Core.Repo, Core.ObanRepo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :core, Core.Repo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at],
  types: Core.PostgrexTypes

config :core, Core.ObanRepo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at],
  types: Core.PostgrexTypes,
  # Share migrations with Core.Repo — both repos point at the same
  # database, so we run migrations once (via Core.Repo's priv/repo/
  # migrations path) and Core.ObanRepo simply opens connections to the
  # already-migrated schema. Without this override Ecto looks for
  # `priv/oban_repo/migrations/` and fails.
  priv: "priv/repo"

config :core, Oban,
  repo: Core.ObanRepo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Stacks.Workers.ImageRetentionJob},
       {"0 4 * * *", Stacks.Workers.TriggerPriceScrapeJob, args: %{batch: true}},
       {"0 6 * * *", Stacks.Workers.RefreshCostsJob},
       {"0 7 * * *", Stacks.Workers.FetchAuthorRSSJob},
       {"0 1 * * *", Stacks.Workers.ListingExpiryJob},
       {"0 3 * * 0", Stacks.Workers.RSSLivenessJob},
       {"0 5 * * *", Stacks.Workers.DbtRefreshJob, args: %{full: true}},
       # Nightly author-source discovery in batch mode. Replaces the
       # per-book enqueue that was exhausting Brave Search's free-tier
       # quota (2000/month ≈ 67/day) within the first few hours of
       # traffic. The batch mode calls `Authors.authors_without_sources/0`
       # and walks it, respecting `BraveClient.@daily_budget` — once
       # budget is spent the remaining authors are picked up on the
       # next night. 08:00 UTC picks a low-traffic window.
       {"0 8 * * *", Stacks.Workers.DiscoverAuthorSourcesJob, args: %{batch: true}},
       # Sweeps expired rows from cache.isbn_resolver_cache and
       # cache.title_search_cache. Runs at 03:30 UTC in the low-traffic
       # window between ImageRetentionJob (02:00) and RSSLivenessJob (03:00).
       {"30 3 * * *", Stacks.Workers.CacheSweepJob},
       # Reaps expired rows from op.guardian_tokens (Issue #124, A2). Access
       # tokens that expire without an explicit logout leave dead rows behind;
       # this purges them via an indexed range delete on `exp`. Midnight UTC.
       {"0 0 * * *", Stacks.Workers.GuardianTokenSweepJob},
       # Reaps abandoned signups: accounts that never confirmed their email and
       # whose 24h confirmation link has expired. Each is erased via the full
       # GDPR right-to-erasure path. 09:00 UTC (an otherwise-empty slot).
       {"0 9 * * *", Stacks.Workers.ExpiredUnverifiedAccountsJob}
     ]}
  ],
  # Queue concurrency is sized against the ObanRepo pool + each queue's real
  # bottleneck, NOT independently. `vision` was 60, but IdentifyBookJob is
  # Modal-bound (the GPU inference is an external HTTP call — upload_p95 ≈ 15s
  # is dominated by Modal, not local slots), so 60 local slots bought ~no
  # throughput while inflating peak ObanRepo ack contention (up to 60 job
  # completions hammering the pool at once → oban_repo_queue_p95 pressure) and
  # BEAM memory on the 512MB machine. 20 is well above realistic concurrent
  # upload load; scale Modal, not local slots, if throughput ever needs more.
  # Total concurrency now 59 (was 99), letting OBAN_POOL_SIZE come down (see
  # runtime.exs) instead of climbing toward Neon's connection ceiling.
  queues: [default: 10, events: 20, vision: 20, scraper: 5, notifications: 3, dbt_refresh: 1]

config :core, CoreWeb.Endpoint,
  # Bandit instead of Cowboy: drops the cowboy/cowlib/ranch chain, which
  # eliminates the unpatched cowlib CVEs (EEF-CVE-2026-43966/43969, Scorecard
  # Vulnerabilities #55 — no cowlib release fixes them). Phoenix 1.8's default.
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: CoreWeb.ErrorJSON], layout: false],
  pubsub_server: Core.PubSub

config :phoenix, :json_library, Jason

config :core, Stacks.Accounts.Guardian,
  issuer: "stacks",
  # Access tokens live 8h by default (Issue #124, A2). This bounds every user
  # session so the guardian_tokens reaper (GuardianTokenSweepJob) has expired
  # rows to purge — without a ttl a token never expires and the store grows
  # unbounded. Admin tokens override this with an explicit {30, :minute} ttl in
  # AdminAuthController.verify_mfa/2.
  ttl: {8, :hours},
  secret_key: "change_me_in_production_via_runtime_exs_at_least_32_chars_long"

# Absolute session-lifetime cap (Issue #179, Phase 1). A session — identified by
# the "sst" (session-start) anchor stamped at login and carried forward across
# every refresh — may be renewed via /api/auth/refresh only up to this window
# from its ORIGINAL issue. #173's silent renewal otherwise lets a session slide
# forever; this bounds it. Past the cap, refresh returns 401 and the #173
# frontend interceptor routes the user to /login. Expressed as `{n, unit}` and
# converted to seconds at the check site; configurable so ops can tune it.
config :core, :session_absolute_cap, {7, :day}

# Refresh-token rotation grace window (Issue #180, Phase 1). #179's reuse gate
# burns the whole family whenever a non-current jti is presented — which
# over-fires on a benign rotation race (an in-flight request or a second tab
# still carrying the JUST-rotated old token). This honours the IMMEDIATELY-
# PREVIOUS token for this window after rotation WITHOUT burning; anything else
# (older token, previous-past-grace, unknown) still burns, so #179's posture
# holds outside the window. Security tradeoff: a stolen just-rotated token is
# honoured for <= this window after the victim rotates — the standard, accepted
# cost of refresh-token rotation grace. Expressed as `{n, unit}`, converted to
# seconds at the check site (Stacks.Accounts); configurable so ops can tune it.
config :core, :session_rotation_grace, {20, :second}

# Guardian.DB — server-side JWT tracking so logout / revoke actually invalidates
# a token (Issue #124, A2). Each issued token is stored in op.guardian_tokens on
# encode_and_sign, checked on every verify, and deleted on revoke. Only "access"
# tokens (regular user sessions) are tracked; "admin_session" tokens have their
# own boot_id + admin_sessions revocation and are passed through.
config :guardian, Guardian.DB,
  repo: Core.Repo,
  prefix: "op",
  schema_name: "guardian_tokens",
  token_types: ["access"]

config :core, :vision_client, Stacks.AI.Client
config :core, :isbn_http_client, Stacks.Books.HttpClient
config :core, :vision_service_url, "http://localhost:8000"
config :core, :vision_hmac_secret, "dev-only-hmac-secret-change-in-production"
config :core, :scraper_client, Stacks.Enrichment.ScraperClient
config :core, :scraper_service_url, "http://localhost:8080"
config :core, :scraper_hmac_secret, "dev-only-scraper-hmac-secret-change-in-production"
config :core, :brave_client, Stacks.Discovery.BraveClient
config :core, :together_client, Stacks.AI.TogetherClient
config :core, :searxng_client, Stacks.Discovery.SearxngClient
config :core, :searxng_url, "http://localhost:8888"
config :core, :dbt_runner, Stacks.Workers.DbtRunner
# Public transparency (#241 / ADR-019) — read-only Fly-Prometheus client for
# the curated live-signal whitelist. The Fly read token + org are runtime
# secrets (see config/runtime.exs); absent ⇒ live section degrades to
# `:unavailable`.
config :core, :transparency_prometheus_client, Stacks.Transparency.Prometheus
# review_fetcher defaults to mock in all environments — no real review API
# integration exists yet. FetchReviewsJob uses this mock to return sample data.
# Replace with a real implementation when a review source API is integrated.
config :core, :review_fetcher, Stacks.Enrichment.MockReviewFetcher
config :core, :rss_fetcher, Stacks.Enrichment.RssFetcher
config :core, :storage, Stacks.Storage.Local

# Cloak vault — AES-256-GCM encryption for sensitive fields at rest.
# The key below is for development only. In production, set CLOAK_KEY.
config :core, Stacks.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="),
      iv_length: 12
    }
  ]

config :core, Stacks.Email.Mailer, adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, Swoosh.ApiClient.Req

# ── Time-zone database + hackney neutralisation ─────────────────────────────
# time_zone_info is the canonical tz database: it bundles IANA data in the
# package (no runtime download), so it works in the Docker prod image with no
# network access or persistent volume. tzdata stays in the lockfile only
# because timex hard-depends on it (timex ← elixir_feed_parser is also a hard
# chain); its autoupdater — the sole hackney call site in the dependency
# graph — is disabled so the hackney 4.x override in mix.exs is never
# exercised through tzdata's 1.x-era API expectations.
config :elixir, :time_zone_database, TimeZoneInfo.TimeZoneDatabase
config :time_zone_info, update: :disabled
config :tzdata, :autoupdate, :disabled

# ex_aws would otherwise default to its hackney adapter at runtime (R2
# storage). Req is already a direct dependency and swoosh uses it too.
config :ex_aws, http_client: ExAws.Request.Req

config :core, :ai_budget,
  daily_limit_cents: 500,
  monthly_limit_cents: 5_000

# ── Enrichment confidence threshold (Issue #167) ────────────────────────────
# Vision-extracted candidates with a per-book `confidence` below this value
# are skipped before ISBN resolution / external lookups / EnrichBookJob
# enqueue. Candidates with no `confidence` field (historical, pre-prompt-v2
# payloads) are processed normally.
config :core, :enrichment_confidence_threshold, 0.5

# ── Per-account login lockout (Issue #161) ──────────────────────────────────
# Defends against credential-stuffing by locking the account after N failed
# logins within a rolling window, regardless of source IP. Lockout duration
# doubles on each subsequent lock within 24 hours up to a cap.
#
#   :login_lockout_threshold              — failed attempts before lock (default 10)
#   :login_lockout_window_seconds         — rolling window for the counter (default 600 / 10 min)
#   :login_lockout_duration_seconds       — initial lock length (default 900 / 15 min)
#   :login_lockout_max_duration_seconds   — cap after exponential backoff (default 7200 / 2 hr)
#   :login_lockout_backoff_window_seconds — window inside which repeat locks compound (default 86_400 / 24 hr)
config :core, :login_lockout_threshold, 10
config :core, :login_lockout_window_seconds, 600
config :core, :login_lockout_duration_seconds, 900
config :core, :login_lockout_max_duration_seconds, 7_200
config :core, :login_lockout_backoff_window_seconds, 86_400

import_config "#{config_env()}.exs"
