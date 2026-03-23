defmodule CoreWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :core

  @session_options [
    store: :cookie,
    key: "_core_key",
    signing_salt: "stacks_signing",
    same_site: "Lax"
  ]

  plug Plug.RequestId

  plug Plug.Static,
    at: "/",
    from: {:core, "priv/static"},
    gzip: false,
    only: ~w(assets textures favicon.ico robots.txt uploads)

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug CORSPlug,
    origin: ["http://localhost:4000"],
    methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    headers: ["Authorization", "Content-Type"],
    max_age: 86_400

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # Prometheus metrics — no auth, restricted to internal network in production
  # (Fly private networking). PromEx renders metrics at /internal/metrics.
  plug PromEx.Plug, prom_ex_module: Core.PromEx, path: "/internal/metrics"

  plug CoreWeb.Router
end
