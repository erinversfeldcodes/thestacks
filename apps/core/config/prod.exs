import Config

config :core, CoreWeb.Endpoint,
  # runtime.exs overwrites :url from PHX_HOST, so this is the build-time
  # fallback only. Kept in step with the real domain so a misconfigured deploy
  # fails over to the right host rather than a stale one.
  url: [host: "readinginthestacks.com", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :info

# Fix Erlang distribution port range for Fly.io's private network.
# Must be in prod.exs (sys.config, baked at build time) — :kernel cannot be
# configured via runtime.exs because it is loaded before config providers run.
config :kernel,
  inet_dist_listen_min: 9100,
  inet_dist_listen_max: 9155
