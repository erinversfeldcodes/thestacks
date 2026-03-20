import Config

config :core, Core.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "stacks_test#{System.get_env("MIX_TEST_PARTITION")}",
  # public first so schema_migrations always lands in public, avoiding a
  # duplicate-table issue when mix test runs ecto.migrate in the apps/core
  # context (which would otherwise find op.schema_migrations before public's).
  parameters: [search_path: "public,op"],
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :core, CoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept-it",
  server: false

config :core, Oban, testing: :manual
config :core, :env, :test

config :core, :rate_limiting_enabled, false
config :core, :vision_client, Stacks.AI.MockClient
config :core, :isbn_http_client, Stacks.Books.MockHttpClient
config :core, :vision_hmac_secret, "test-hmac-secret"
config :core, :scraper_client, Stacks.Enrichment.MockScraperClient
config :core, :scraper_hmac_secret, "test-scraper-hmac-secret"
config :core, :brave_client, Stacks.Discovery.MockBraveClient

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
config :core, :require_email_confirmation, false

config :logger, level: :warning
