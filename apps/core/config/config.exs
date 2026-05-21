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
       {"30 3 * * *", Stacks.Workers.CacheSweepJob}
     ]}
  ],
  queues: [default: 10, events: 20, vision: 60, scraper: 5, notifications: 3, dbt_refresh: 1]

config :core, CoreWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: CoreWeb.ErrorJSON], layout: false],
  pubsub_server: Core.PubSub

config :phoenix, :json_library, Jason

config :core, Stacks.Accounts.Guardian,
  issuer: "stacks",
  secret_key: "change_me_in_production_via_runtime_exs_at_least_32_chars_long"

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

config :core, :ai_budget,
  daily_limit_cents: 500,
  monthly_limit_cents: 5_000

# ── Enrichment confidence threshold (Issue #167) ────────────────────────────
# Vision-extracted candidates with a per-book `confidence` below this value
# are skipped before ISBN resolution / external lookups / EnrichBookJob
# enqueue. Candidates with no `confidence` field (historical, pre-prompt-v2
# payloads) are processed normally.
config :core, :enrichment_confidence_threshold, 0.5

# ── Selective vision verification (Issue #169) ──────────────────────────────
# When the analyze pass returns candidates with confidence below
# `:verification_threshold_high`, the moderation pipeline calls the sidecar
# `/verify` endpoint to cross-check each candidate's title-searched cover
# against the uploaded image. Candidates with max confidence below
# `:verification_threshold_low` are rejected outright as `:uncertain` (no
# verification call). `:verification_threshold_match` is the threshold the
# `/verify` response's own confidence must clear to count as a match.
config :core, :verification_threshold_high, 0.7
config :core, :verification_threshold_low, 0.3
config :core, :verification_threshold_match, 0.7

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
