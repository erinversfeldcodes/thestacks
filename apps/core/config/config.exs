import Config

config :core,
  ecto_repos: [Core.Repo, Core.ObanRepo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :core, Core.Repo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at],
  types: Core.PostgrexTypes

config :core, Core.ObanRepo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at],
  types: Core.PostgrexTypes,
  priv: "priv/repo"

config :core, Oban,
  repo: Core.ObanRepo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Stacks.Workers.ImageRetentionJob},
       {"30 2 * * *", Stacks.Workers.LibraryImportRowRetentionJob},
       {"0 4 * * *", Stacks.Workers.TriggerPriceScrapeJob, args: %{batch: true}},
       {"0 6 * * *", Stacks.Workers.RefreshCostsJob},
       {"0 7 * * *", Stacks.Workers.FetchAuthorRSSJob},
       {"30 7 * * 1", Stacks.Workers.DiscoverBookstoreEventsJob, args: %{batch: true}},
       {"0 1 * * *", Stacks.Workers.ListingExpiryJob},
       {"0 3 * * 0", Stacks.Workers.RSSLivenessJob},
       {"0 5 * * *", Stacks.Workers.DbtRefreshJob, args: %{full: true}},
       {"0 8 * * *", Stacks.Workers.DiscoverAuthorSourcesJob, args: %{batch: true}},
       {"30 4 * * *", Stacks.Workers.BuildScraperIndexJob},
       {"0 5 * * 0", Stacks.Workers.MatchStoreCatalogueJob},
       {"0 6 * * 0", Stacks.Workers.GeocodeBookstoresJob},
       {"30 3 * * *", Stacks.Workers.CacheSweepJob},
       {"0 0 * * *", Stacks.Workers.GuardianTokenSweepJob},
       {"0 9 * * *", Stacks.Workers.ExpiredUnverifiedAccountsJob},
       {"30 9 * * *", Stacks.Workers.ExpiredInvitesSweepJob},
       {"45 9 * * *", Stacks.Workers.ExpiredEmailChangesJob}
     ]}
  ],
  queues: [default: 10, events: 20, vision: 20, scraper: 5, notifications: 3, dbt_refresh: 1]

config :core, CoreWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: CoreWeb.ErrorJSON], layout: false],
  pubsub_server: Core.PubSub

config :phoenix, :json_library, Jason

config :core, Stacks.Accounts.Guardian,
  issuer: "stacks",
  ttl: {8, :hours},
  secret_key: "change_me_in_production_via_runtime_exs_at_least_32_chars_long"

config :core, :session_absolute_cap, {7, :day}

config :core, :session_rotation_grace, {20, :second}

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
config :core, :transparency_prometheus_client, Stacks.Transparency.Prometheus
config :core, :rss_fetcher, Stacks.Enrichment.RssFetcher
config :core, :storage, Stacks.Storage.Local

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

# TODO(email): TEMPORARY STOPGAP sender — Resend's `onboarding@resend.dev` test
# address. It CANNOT deliver to real users: verified 2026-07 that Resend's
# onboarding mode only accepts the Resend-account owner's own email, AND only when
# the recipient has no display name (a `{name, addr}` "to" 403s). So real
# verification/reset emails will NOT reach actual signups with this sender.
# ACTION: once a domain is verified at resend.com/domains, flip this to
# `{"The Stacks", "noreply@thestacks.app"}` (or set the EMAIL_FROM env var) — that
# is the ONLY remaining step to make prod email actually work. Overridable per-env
# via EMAIL_FROM (config/runtime.exs).
config :core, :email_from, {"The Stacks", "onboarding@resend.dev"}

config :swoosh, :api_client, Swoosh.ApiClient.Req

config :elixir, :time_zone_database, TimeZoneInfo.TimeZoneDatabase
config :time_zone_info, update: :disabled
config :tzdata, :autoupdate, :disabled

config :ex_aws, http_client: ExAws.Request.Req

config :core, :ai_budget,
  daily_limit_cents: 500,
  monthly_limit_cents: 5_000

config :core, :enrichment_confidence_threshold, 0.5

config :core, :login_lockout_threshold, 10
config :core, :login_lockout_window_seconds, 600
config :core, :login_lockout_duration_seconds, 900
config :core, :login_lockout_max_duration_seconds, 7_200
config :core, :login_lockout_backoff_window_seconds, 86_400

# Argon2id memory cost. Left unset, argon2_elixir defaults to m_cost 16
# (2^16 KiB = 64 MiB per hash). With ArgonPool bounding concurrency to 2 that is
# 128 MiB of peak hashing on a 512 MB VM whose BEAM baseline has grown with the
# app — the OOM the 0f4a5193 pool only band-aided. m_cost 15 (2^15 KiB = 32 MiB)
# halves per-hash memory (2×32 = 64 MiB peak) and still sits above the OWASP
# Argon2id floor of 19 MiB — so this is a root-cause fix, not a VM-size workaround.
# The cost is encoded in each stored hash, so existing passwords keep verifying;
# only new/rehashed passwords use the new cost.
config :argon2_elixir, m_cost: 15

import_config "#{config_env()}.exs"
