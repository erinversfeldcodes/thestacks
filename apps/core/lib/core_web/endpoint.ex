defmodule CoreWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :core

  # ⛔ THE `Plug.Session` COOKIE STORE WAS DELETED HERE, 2026-10-23, and the
  # reason is recorded because "add it back" is the obvious next edit.
  #
  # It configured a cookie session store (`key: "_core_key"`) and **nothing read
  # or wrote it** — measured zero `get_session` / `put_session` /
  # `fetch_session` / `clear_session` call sites across `core_web` and
  # `stacks_web`, plus zero flash, zero CSRF, zero LiveView and no `socket`
  # declaration. Sessions are carried by `StacksWeb.Plugs.SessionCookie`, which
  # reads a plain cookie and does not use this store.
  #
  # ⚠️ Deletion rather than reuse, which is the part that decided it. The block
  # carried a hardcoded signing salt — a committed literal in a tracked file.
  # Inert while nothing used the store; a real finding the moment a session rode
  # on it, because that salt is what would sign it. It also lacked
  # `secure: true`.
  #
  # ⚠️ The salt's VALUE is deliberately not quoted here. It is dead, but
  # restating a secret-shaped literal in a comment leaves the same string in the
  # same tracked file and makes "is there a committed salt?" answer yes to a
  # grep — which is the question someone will ask of this file next.
  #
  # ⚖️ And the hazard that is about neither: its `same_site: "Lax"`
  # COINCIDENTALLY matched what the cookie-session decision argues for on its
  # own reasoning, so an
  # unreviewed config agreed with a reviewed decision on one line and read as
  # vetted. The next reader would infer the other two options had been
  # considered. They had not. Starting from nothing forced all three decisions
  # to be made explicitly.
  plug Plug.RequestId

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

  plug StacksWeb.Plugs.MetricsAuth
  plug PromEx.Plug, prom_ex_module: Core.PromEx, path: "/internal/metrics"

  plug StacksWeb.Plugs.DepsCheck

  plug StacksWeb.Plugs.RouteGroup

  plug CoreWeb.Router
end
