import Config

config :core, Core.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "stacks_dev",
  parameters: [search_path: "public,op"],
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :core, CoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base:
    "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept-it",
  watchers: [
    node: ["build.js", "--watch", cd: Path.expand("../apps/core/assets", __DIR__)]
  ]

config :core, :rate_limiting_enabled, false
config :core, :smoke_tests_enabled, true

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
