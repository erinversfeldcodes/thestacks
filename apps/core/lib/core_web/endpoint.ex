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

  # Prometheus metrics — auth-gated by StacksWeb.Plugs.MetricsAuth: requires
  # an Authorization: Bearer <METRICS_SCRAPE_TOKEN> header. The plug halts
  # with 401 for unauthorised callers before PromEx.Plug ever sees the
  # request. No IP allowlist — fly-proxy re-originates public traffic over
  # 6PN so conn.remote_ip is not a trust signal.
  plug StacksWeb.Plugs.MetricsAuth
  plug PromEx.Plug, prom_ex_module: Core.PromEx, path: "/internal/metrics"

  # Tag every request with a :route_group before the router dispatches so
  # phoenix.router_dispatch.stop metadata carries the group. Feeds the SLO
  # gate in Issue #136.
  plug StacksWeb.Plugs.RouteGroup

  plug CoreWeb.Router
end
