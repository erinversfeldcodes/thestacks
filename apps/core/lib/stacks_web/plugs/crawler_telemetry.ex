defmodule StacksWeb.Plugs.CrawlerTelemetry do
  @moduledoc """
      Emits a telemetry counter for `robots.txt` fetches.

      `robots.txt` is served by `Plug.Static` in the endpoint, which halts the conn
      and sends the file before any controller runs — so this plug must be mounted
      **before** `Plug.Static` in `CoreWeb.Endpoint` to observe the request.

      Emits `[:stacks,:crawler,:robots_fetch]` with `%{count: 1}` and empty
      metadata when the request path is `/robots.txt`. No request attributes are
      tagged, so there is no cardinality or user-input leakage concern.
  """

  @behaviour Plug

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{request_path: "/robots.txt"} = conn, _opts) do
    :telemetry.execute([:stacks, :crawler, :robots_fetch], %{count: 1}, %{})
    conn
  end

  def call(conn, _opts), do: conn
end
