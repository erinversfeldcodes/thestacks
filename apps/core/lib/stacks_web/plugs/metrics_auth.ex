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

  ## Why bearer-only (no IP allowlist)

  On Fly.io the `[http_service]` block in `deploy/fly.core.toml` does not
  enable `proxy_protocol`, so every externally-initiated HTTPS request
  re-originates over Fly's internal 6PN network after terminating at
  fly-proxy. `conn.remote_ip` for public callers is therefore always an
  `fdaa::/16` 6PN address — indistinguishable from legitimate in-cluster
  scrapers. A 6PN allowlist would bypass the bearer check for every public
  caller, so the plug enforces bearer-only. Internal scrapers MUST carry the
  same bearer token as external ones.
  """

  @behaviour Plug

  import Plug.Conn

  @internal_prefix "/internal/"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: @internal_prefix <> _} = conn, _opts) do
    if authorized?(conn), do: conn, else: halt_with_401(conn)
  end

  def call(conn, _opts), do: conn

  @doc false
  @spec authorized?(Plug.Conn.t()) :: boolean()
  def authorized?(conn), do: valid_bearer?(conn)

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
