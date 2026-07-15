defmodule StacksWeb.Plugs.MetricsAuth do
  @moduledoc """
  Bearer-token auth plug guarding every `/internal/*` route.

  A request is allowed through iff the `authorization` header is
  `Bearer <token>` where the token matches
  `Application.get_env(:core, :metrics_scrape_token)`.

  Non-internal paths pass through untouched so the plug is safe to install
  at the endpoint. Currently guards:

    * `/internal/metrics`   — PromEx scrape target (Issue #136).
    * `/internal/deps-check` — synthetic dependency probe (cold-start
      coverage for SearXNG etc., Issue #136 post-launch follow-up).

  The token is shared across all internal routes because the only caller
  is the SLO gate — introducing per-route tokens would complicate rotation
  without adding real isolation.

  ## Why a bearer is required on the public edge (no bare-IP allowlist)

  On Fly.io the `[http_service]` block in `deploy/fly.core.toml` does not
  enable `proxy_protocol`, so every externally-initiated HTTPS request
  re-originates over Fly's internal 6PN network after terminating at
  fly-proxy. `conn.remote_ip` for public callers is therefore always an
  `fdaa::/16` 6PN address — indistinguishable *by remote_ip alone* from a
  legitimate in-cluster scraper. A bare 6PN allowlist would bypass the
  bearer for every public caller, so `remote_ip` is **not** a sufficient
  trust signal on its own.

  ## The Fly managed-Prometheus bypass (Issue #232)

  Fly's managed Prometheus scrapes the machine **directly over 6PN** (the
  `[metrics]` block in `deploy/fly.core.toml`); it never traverses
  fly-proxy. fly-proxy, by contrast, **sets and overwrites** the
  `fly-client-ip` header on *every* request it forwards from the public edge
  (the same unspoofable signal `RateLimiter`/`AuthController` key on — Issue
  #176). So the two callers are distinguishable after all:

    * public request  → arrived via fly-proxy → has `fly-client-ip`.
    * 6PN scrape      → arrived directly      → has **no** `fly-client-ip`.

  `/internal/metrics` (only) is therefore allowed **without a bearer** iff
  the request both (a) originates from the Fly 6PN range (`fdaa::/16`) and
  (b) carries **no** `fly-client-ip` header — i.e. it did not come through
  the public edge. A public caller cannot forge this: fly-proxy always adds
  `fly-client-ip` and the client cannot strip it. The public path — and
  every other `/internal/*` route (e.g. `/internal/deps-check`) — still
  requires the bearer.
  """

  @behaviour Plug

  import Plug.Conn

  @internal_prefix "/internal/"
  @metrics_path "/internal/metrics"

  # Fly 6PN addresses live in fdaa::/16 — the first 16-bit group is 0xFDAA.
  @fly_6pn_group 0xFDAA

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: @internal_prefix <> _} = conn, _opts) do
    if authorized?(conn), do: conn, else: halt_with_401(conn)
  end

  def call(conn, _opts), do: conn

  @doc false
  @spec authorized?(Plug.Conn.t()) :: boolean()
  def authorized?(conn), do: valid_bearer?(conn) or fly_private_metrics_scrape?(conn)

  # Narrowly-scoped, unauthenticated bypass for Fly's managed-Prometheus
  # scrape of `/internal/metrics` over the private 6PN network. Requires
  # BOTH a 6PN remote_ip AND the absence of the fly-proxy-injected
  # `fly-client-ip` header, so no public-edge caller can reach it without the
  # bearer. Scoped to the metrics path only — never /internal/deps-check.
  defp fly_private_metrics_scrape?(%Plug.Conn{request_path: @metrics_path} = conn) do
    fly_6pn_remote_ip?(conn.remote_ip) and not proxied_from_public_edge?(conn)
  end

  defp fly_private_metrics_scrape?(_conn), do: false

  # fly-proxy sets `fly-client-ip` on every request it forwards from the
  # public edge; a direct 6PN scrape has none. Presence ⇒ came via the edge.
  defp proxied_from_public_edge?(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip | _] when ip != "" -> true
      _ -> false
    end
  end

  defp fly_6pn_remote_ip?({@fly_6pn_group, _, _, _, _, _, _, _}), do: true
  defp fly_6pn_remote_ip?(_), do: false

  defp valid_bearer?(conn) do
    expected = Application.get_env(:core, :metrics_scrape_token)

    with true <- is_binary(expected) and expected != "",
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- constant_time_eq?(token, expected) do
      true
    else
      _ -> false
    end
  end

  # Constant-time comparison to keep the check non-timing-leaky.
  defp constant_time_eq?(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp constant_time_eq?(_, _), do: false

  defp halt_with_401(conn) do
    conn
    |> send_resp(401, "")
    |> halt()
  end
end
