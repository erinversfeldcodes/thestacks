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
  ecto_repos: [Core.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :core, Core.Repo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at],
  types: Core.PostgrexTypes

config :core, Oban,
  repo: Core.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Stacks.Workers.ImageRetentionJob},
       {"0 4 * * *", Stacks.Workers.TriggerPriceScrapeJob, args: %{batch: true}},
       {"0 6 * * *", Stacks.Workers.RefreshCostsJob},
       {"0 7 * * *", Stacks.Workers.FetchAuthorRSSJob},
       {"0 1 * * *", Stacks.Workers.ListingExpiryJob},
       {"0 3 * * 0", Stacks.Workers.RSSLivenessJob}
     ]}
  ],
  queues: [default: 10, events: 20, vision: 5, scraper: 5, notifications: 3]

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
config :core, :review_fetcher, Stacks.Enrichment.MockReviewFetcher
config :core, :rss_fetcher, Stacks.Enrichment.RssFetcher
config :core, :require_email_confirmation, false
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

import_config "#{config_env()}.exs"
