defmodule StacksWeb.Plugs.MetricsAuth do
  @moduledoc """
  Bearer-token auth plug guarding every `/internal/*` route.

  A request is allowed through iff the `authorization` header is
  `Bearer <token>` where the token matches
  `Application.get_env(:core, :metrics_scrape_token)`.

  Non-internal paths pass through untouched so the plug is safe to install
  at the endpoint. Currently guards:

    * `/internal/metrics`   — PromEx exposition, read by the SLO gate
      (Issue #136). Metrics reach VictoriaMetrics by push, not by a scrape
      of this route — see the 6PN section below.
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

  ## A former 6PN bypass was removed (#393)

  There used to be an unauthenticated bypass for an in-cluster scrape of
  `/internal/metrics` over the Fly 6PN network (added for Fly's managed
  Prometheus, Issue #232). ADR-021 (#253) replaced scraping with a push
  (`Core.PromEx.MetricsPusher` POSTs to self-hosted VictoriaMetrics, which does
  not scrape back), and #323 removed the Fly `[metrics]` block — so the bypass
  had **no caller** and had never ingested a sample (#248). It was dead
  auth-relaxing code, so it is gone: the only live caller of `/internal/metrics`,
  `scripts/check-slo-gate.sh`, arrives over the public edge with the bearer. If a
  future in-cluster scraper needs bearer-less access, reintroduce a bypass
  deliberately (and with a test), rather than carrying an unreachable one.
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
