defmodule StacksWeb.Plugs.RequireRole do
  @moduledoc """
  Plug that restricts access to users with a specific role.

  ## Usage in router

      pipeline :require_owner do
        plug StacksWeb.Plugs.RequireRole, role: "owner"
      end

  Returns 403 if the authenticated user does not have the required role.

  ## Which user it reads

  Two upstream pipelines establish a user by two different routes:
  `:authenticated` leaves it in Guardian's process-backed resource, while
  `:admin` (`StacksWeb.Plugs.AdminAuthPipeline`) loads it itself and assigns
  `:current_user`. This plug accepts either, so `:require_owner` composes after
  `:admin` as well as after `:authenticated`.

  That composition matters for mutating admin routes (#340). The admin login
  refuses a non-owner, so re-checking looks redundant — but an admin token
  outlives the role it was minted under: demote the account and the pipeline
  keeps loading the user for the rest of the session's 30 minutes. Checking the
  role where the write happens, and not only where the session began, is the
  point.
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
