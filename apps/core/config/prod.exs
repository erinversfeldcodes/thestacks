import Config

config :core, CoreWeb.Endpoint,
  url: [host: "thestacks.fly.dev", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :info

# Fix Erlang distribution port range for Fly.io's private network.
# Must be in prod.exs (sys.config, baked at build time) — :kernel cannot be
# configured via runtime.exs because it is loaded before config providers run.
config :kernel,
  inet_dist_listen_min: 9100,
  inet_dist_listen_max: 9155
