defmodule StacksWeb.Plugs.MetricsAuth do
  @moduledoc """
  Auth plug guarding `/internal/metrics`.

  A request is allowed through iff one of:

    * `conn.remote_ip` is inside Fly's private 6PN block (`fd00::/8`)
    * the `authorization` header is `Bearer <token>` where the token matches
      `Application.get_env(:core, :metrics_scrape_token)`.

  Every other request is halted with `401`. Non-metrics paths are passed
  through untouched so the plug is safe to install at the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  @metrics_path "/internal/metrics"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: @metrics_path} = conn, _opts) do
    if authorized?(conn), do: conn, else: halt_with_401(conn)
  end

  def call(conn, _opts), do: conn

  @doc false
  @spec authorized?(Plug.Conn.t()) :: boolean()
  def authorized?(conn) do
    fly_6pn_address?(conn.remote_ip) or valid_bearer?(conn)
  end

  # Fly private 6PN uses the fd00::/8 unique local address range. Any IPv6
  # whose first byte (high 8 bits of the first 16-bit group) equals 0xfd is
  # inside that block.
  defp fly_6pn_address?({a, _, _, _, _, _, _, _}) when is_integer(a) do
    Bitwise.bsr(a, 8) == 0xFD
  end

  defp fly_6pn_address?(_), do: false

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
