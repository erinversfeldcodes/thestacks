defmodule StacksWeb.Plugs.RequireRole do
  @moduledoc """
      Restricts a route to users with a given role
      (`plug StacksWeb.Plugs.RequireRole, role: "owner"`).
      Accepts the user from EITHER upstream pipeline — Guardian's resource
      (`:authenticated`) or `conn.assigns[:current_user]` (`:admin`) — so it
      composes after both. That composition matters: an admin token outlives the
      role it was minted under, so a demoted account keeps authenticating for the
      token's remaining ttl; this plug is what stops it reaching owner-only
      surfaces.

      Denial is `403 Forbidden` by default. Pass `on_denied: :not_found` to halt
      with the application's generic `404 Not Found` body instead — the same body
      an unmatched route produces. An owner-only surface guarded this way is
      indistinguishable from a route that does not exist, so it never reveals to a
      non-owner that the route is real and merely gated. Use `:not_found` where
      leaking a surface's existence is itself a concern, and order it ahead of any
      second-factor gate so a caller who can never be authorised is never asked to
      strengthen a session they could not use.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts.Guardian

  def init(opts), do: opts

  def call(conn, opts) do
    required_role = Keyword.fetch!(opts, :role)
    on_denied = Keyword.get(opts, :on_denied, :forbidden)
    user = Guardian.Plug.current_resource(conn) || conn.assigns[:current_user]

    case user do
      %{role: ^required_role} ->
        conn

      _ ->
        deny(conn, required_role, on_denied)
    end
  end

  # Renders the framework's own 404 body rather than restating it, so the two
  # cannot drift: whatever an unmatched route returns is what a denied caller
  # returns, and the surface stays indistinguishable from one that is not there.
  defp deny(conn, _required_role, :not_found) do
    # The API's own "this route does not exist" body (CoreWeb.PageController's
    # :api_not_found catch-all), so an owner-gated surface is byte-identical to a
    # genuinely absent one and never reveals it is real and merely gated.
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
    |> halt()
  end

  defp deny(conn, required_role, _forbidden) do
    conn
    |> put_status(403)
    |> json(%{error: "Forbidden — #{required_role} role required"})
    |> halt()
  end
end
