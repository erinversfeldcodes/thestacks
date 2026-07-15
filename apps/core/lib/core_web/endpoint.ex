defmodule CoreWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :core

  @session_options [
    store: :cookie,
    key: "_core_key",
    signing_salt: "stacks_signing",
    same_site: "Lax"
  ]

  plug Plug.RequestId

  # Must precede Plug.Static — it serves /robots.txt and halts before any
  # later plug runs, so crawler-fetch telemetry has to be observed here first.
  plug StacksWeb.Plugs.CrawlerTelemetry

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

  # Prometheus metrics — auth-gated by StacksWeb.Plugs.MetricsAuth: public
  # callers need an Authorization: Bearer <METRICS_SCRAPE_TOKEN> header; the
  # plug halts with 401 before PromEx.Plug sees the request. The one bypass
  # is Fly's managed-Prometheus scrape of /internal/metrics arriving directly
  # over 6PN (fdaa::/16 remote_ip AND no fly-proxy `fly-client-ip` header) —
  # see the plug's @moduledoc. remote_ip alone is not a trust signal.
  plug StacksWeb.Plugs.MetricsAuth
  plug PromEx.Plug, prom_ex_module: Core.PromEx, path: "/internal/metrics"

  # Synthetic dependency probe for SLO gate cold-start coverage. Handled at
  # the endpoint level (before the router) so it (a) never appears in
  # `core_prom_ex_phoenix_http_requests_total` and therefore can't skew
  # `real_5xx_rate`, (b) never triggers route-group tagging, and (c) short-
  # circuits dependency-heavy Plug pipelines that the real `/api/*` routes
  # run. Bearer auth is provided by the MetricsAuth plug above.
  plug StacksWeb.Plugs.DepsCheck

  # Tag every request with a :route_group before the router dispatches so
  # phoenix.router_dispatch.stop metadata carries the group. Feeds the SLO
  # gate in Issue #136.
  plug StacksWeb.Plugs.RouteGroup

  plug CoreWeb.Router
end
