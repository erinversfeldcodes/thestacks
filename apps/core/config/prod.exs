import Config

config :core, CoreWeb.Endpoint,
  url: [host: "readinginthestacks.com", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :info

config :kernel,
  inet_dist_listen_min: 9100,
  inet_dist_listen_max: 9155
