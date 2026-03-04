import Config

config :core, CoreWeb.Endpoint,
  url: [host: "thestacks.fly.dev", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :info
