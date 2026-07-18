import Config

config :core, Core.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "stacks_test#{System.get_env("MIX_TEST_PARTITION")}",
  parameters: [search_path: "public,op"],
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Prevent parallel preload tasks from being dropped during peak sandbox
  # contention (28 concurrent cases, each preloading multiple associations).
  queue_target: 5_000,
  queue_interval: 10_000

# Core.ObanRepo shares Core.Repo's database in test — the prod
# separation is purely for connection-pool isolation, not schema
# isolation. Same database name, same sandbox pool adapter so tests
# that enqueue Oban jobs can still assert against them via
# `Oban.drain_queue` etc. without a cross-repo transaction dance.
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

# Tests use Core.Repo for Oban (overriding config.exs's Core.ObanRepo).
# Production keeps the dedicated Core.ObanRepo for pool isolation, but
# in tests both repos point at the same DB (see test.exs above), and
# the multi-repo sandbox ownership dance gets complicated to reason
# about — cross-process event handlers trigger telemetry that enqueues
# Oban jobs, which can happen outside the test's sandbox owner PIDs
# and leak jobs into later tests. Pointing Oban back at Core.Repo in
# test keeps every insert inside the one owner's transaction.
config :core, Oban, testing: :manual, repo: Core.Repo

# Strip Core.ObanRepo from the ecto_repos list in test env so
# `mix ecto.create/migrate` don't iterate over a second (redundant)
# repo. Production keeps both listed in config.exs so the ObanRepo
# is started and has its own pool; tests skip it entirely because
# Oban itself is configured back to Core.Repo above.
config :core, ecto_repos: [Core.Repo]

config :core, :env, :test

# Age-gating is shipped dark in production (ADR-020) but ON in test so the full
# enforcement suite (AgeGate.enforce/2, Books.maybe_exclude_age_gated/2,
# Visibility.check_age_gate/3) keeps exercising the gate. Flag-off no-op tests
# flip this to false locally via Application.put_env and restore it.
config :core, :age_gating_enabled, true

config :core, :rate_limiting_enabled, false
config :core, :vision_client, Stacks.AI.MockClient

# Fail any test that emits an event whose payload drifts from the declared
# Stacks.Events.PayloadContract (keys/version). Off in prod by default.
config :core, :validate_event_payload_contract, true
config :core, :isbn_http_client, Stacks.Books.MockHttpClient
# Disable ISBN cache in test — ETS is global, tests register different
# mock responses for the same ISBN, so caching would cross-contaminate.
config :core, :isbn_resolver_cache_enabled, false
# Same reasoning for the title-search cache — tests reuse titles like
# "The Great Gatsby" across scenarios with different expected ISBNs.
config :core, :title_search_cache_enabled, false
# Disable the Postgres L2 layer in tests. The existing cache unit tests
# assume an empty state after `invalidate_all/0`; keeping the DB layer
# enabled would bleed cached entries across tests (the sandbox rolls
# back changes per-test but the initial state after invalidate_all would
# still vary). DB-layer behaviour is exercised by its own integration
# tests that opt-in to persistent mode.
config :core, :persistent_cache_enabled, false
config :core, :vision_hmac_secret, "test-hmac-secret"
config :core, :scraper_client, Stacks.Enrichment.MockScraperClient
config :core, :scraper_hmac_secret, "test-scraper-hmac-secret"
config :core, :brave_client, Stacks.Discovery.MockBraveClient
config :core, :searxng_client, Stacks.Discovery.MockSearxngClient
config :core, :together_client, Stacks.AI.MockTogetherClient
config :core, :rss_fetcher, Stacks.Enrichment.MockRssFetcher
config :core, :storage, Stacks.Storage.Mock
config :core, :dbt_runner, Stacks.Workers.MockDbtRunner
config :core, :transparency_prometheus_client, Stacks.Transparency.MockPrometheusClient

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
