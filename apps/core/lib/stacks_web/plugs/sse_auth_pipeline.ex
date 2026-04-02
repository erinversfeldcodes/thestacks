defmodule StacksWeb.Plugs.SSEAuthPipeline do
  @moduledoc """
  Guardian authentication plug for SSE endpoints.

  Reads JWT from the `?token=` query parameter instead of the `Authorization`
  header, since browser `EventSource` API cannot set custom request headers.

  Security tradeoff: tokens in query parameters appear in server access logs
  and browser history. Mitigations: tokens are short-lived (Guardian TTL applies),
  and the SSE endpoint is read-only (no state mutation on auth alone).
  """

  import Plug.Conn

  alias Stacks.Accounts.Guardian

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    token = conn.query_params["token"]
    authenticate(conn, token)
  end

  defp authenticate(conn, nil) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: "unauthorized"})
    |> halt()
  end

  defp authenticate(conn, token) do
    with {:ok, claims} <- Guardian.decode_and_verify(token),
         {:ok, user} <- Guardian.resource_from_claims(claims) do
      Guardian.Plug.put_current_resource(conn, user)
    else
      _error ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
