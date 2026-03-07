import Config

config :core,
  ecto_repos: [Core.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :core, Core.Repo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at]

config :core, Oban,
  repo: Core.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Stacks.Workers.ImageRetentionJob}
     ]}
  ],
  queues: [default: 10, events: 20, vision: 5, scraper: 5]

config :core, CoreWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: CoreWeb.ErrorJSON], layout: false],
  pubsub_server: Core.PubSub

config :phoenix, :json_library, Jason

config :core, Stacks.Accounts.Guardian,
  issuer: "stacks",
  secret_key: "change_me_in_production_via_runtime_exs_at_least_32_chars_long"

config :core, :vision_client, Stacks.AI.Client
config :core, :vision_sidecar_url, "http://localhost:8000"

config :core, :ai_budget,
  daily_limit_cents: 500,
  monthly_limit_cents: 5_000

import_config "#{config_env()}.exs"
