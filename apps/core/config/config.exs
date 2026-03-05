import Config

config :core,
  ecto_repos: [Core.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :core, Core.Repo,
  migration_timestamps: [type: :utc_datetime_usec]

config :core, Oban,
  repo: Core.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [default: 10, events: 20, vision: 5, scraper: 5]

config :core, CoreWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: CoreWeb.ErrorJSON], layout: false],
  pubsub_server: Core.PubSub

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
