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
    only: ~w(css elm.js public favicon.ico robots.txt uploads)

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug CORSPlug,
    origin: ["http://localhost:4001"],
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
  plug CoreWeb.Router
end
