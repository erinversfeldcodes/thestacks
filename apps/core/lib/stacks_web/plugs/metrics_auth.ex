defmodule StacksWeb.Plugs.MetricsAuth do
  @moduledoc """
  Bearer-token auth for every `/internal/*` route (non-internal paths
  pass through, so it installs at the endpoint). Allowed iff
  `authorization: Bearer <token>` matches `:metrics_scrape_token`. Guards
  `/internal/metrics` (PromEx exposition, read by the SLO gate — VM gets
  metrics by push, not via this route) and `/internal/deps-check`. One
  shared token: the only caller is the SLO gate, and per-route tokens
  would complicate rotation without real isolation. Required because the
  public edge terminates at the Fly proxy — without it these routes are
  internet-reachable. Compares via `Plug.Crypto.secure_compare/2`.
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
