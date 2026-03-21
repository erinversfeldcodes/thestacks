defmodule StacksWeb.Plugs.RequireRole do
  @moduledoc """
  Plug that restricts access to users with a specific role.

  ## Usage in router

      pipeline :require_owner do
        plug StacksWeb.Plugs.RequireRole, role: "owner"
      end

  Returns 403 if the authenticated user does not have the required role.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts.Guardian

  def init(opts), do: opts

  def call(conn, opts) do
    required_role = Keyword.fetch!(opts, :role)
    user = Guardian.Plug.current_resource(conn)

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
