defmodule StacksWeb.Plugs.RequireRole do
  @moduledoc """
  Restricts a route to users with a given role
  (`plug StacksWeb.Plugs.RequireRole, role: "owner"`); 403 otherwise.
  Accepts the user from EITHER upstream pipeline — Guardian's resource
  (`:authenticated`) or `conn.assigns[:current_user]` (`:admin`) — so
  `:require_owner` composes after both. That composition matters: an admin
  token outlives the role it was minted under, so a demoted account keeps
  authenticating for the token's remaining ttl; this plug is what stops it
  mutating owner-only surfaces (340).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts.Guardian

  def init(opts), do: opts

  def call(conn, opts) do
    required_role = Keyword.fetch!(opts, :role)
    user = Guardian.Plug.current_resource(conn) || conn.assigns[:current_user]

    case user do
      %{role: ^required_role} ->
        conn

      _ ->
        conn
        |> put_status(403)
        |> json(%{error: "Forbidden — #{required_role} role required"})
        |> halt()
    end
  end
end
