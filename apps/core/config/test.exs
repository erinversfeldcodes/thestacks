import Config

config :core, Core.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "stacks_test#{System.get_env("MIX_TEST_PARTITION")}",
  parameters: [search_path: "public,op"],
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  queue_target: 5_000,
  queue_interval: 10_000

config :core, Core.ObanRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "stacks_test#{System.get_env("MIX_TEST_PARTITION")}",
  parameters: [search_path: "public,op"],
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :core, CoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept-it",
  server: false

config :core, Oban, testing: :manual, repo: Core.Repo

config :core, ecto_repos: [Core.Repo]

config :core, :env, :test

config :core, :age_gating_enabled, true

config :core, :rate_limiting_enabled, false
config :core, :vision_client, Stacks.AI.MockClient

config :core, :validate_event_payload_contract, true
config :core, :isbn_http_client, Stacks.Books.MockHttpClient
config :core, :isbn_resolver_cache_enabled, false
config :core, :title_search_cache_enabled, false
config :core, :persistent_cache_enabled, false
config :core, :vision_hmac_secret, "test-hmac-secret"
config :core, :scraper_client, Stacks.Enrichment.MockScraperClient
config :core, :scraper_hmac_secret, "test-scraper-hmac-secret"
config :core, :brave_client, Stacks.Discovery.MockBraveClient
config :core, :searxng_client, Stacks.Discovery.MockSearxngClient
config :core, :together_client, Stacks.AI.MockTogetherClient
config :core, :rss_fetcher, Stacks.Enrichment.MockRssFetcher
config :core, :circuit_breaker_probe_http_client, Stacks.Testing.DisabledProbeHttpClient
config :core, :log_shipper_probe_http_client, Stacks.Testing.DisabledProbeHttpClient
config :core, :storage, Stacks.Storage.Mock
config :core, :dbt_runner, Stacks.Workers.MockDbtRunner
config :core, :transparency_prometheus_client, Stacks.Transparency.MockPrometheusClient

# The DB watchdog would read the SQL sandbox's ownership errors as an outage
# and melt :neon_fuse mid-suite; tests exercise it via the :db_watchdog_ping seam.
config :core, :db_watchdog_enabled, false

config :core, :geocoder, Stacks.Geocoding.Mock

config :core, Stacks.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="),
      iv_length: 12
    }
  ]

config :core, Stacks.Email.Mailer, adapter: Swoosh.Adapters.Test

config :core, :sse_max_timeout_ms, 500

config :logger, level: :warning

config :core, :lazy_price_refresh, false
