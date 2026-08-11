defmodule StacksWeb.Plugs.RequireConfirmedEmail do
  @moduledoc """
    Plug that rejects authenticated users who have not confirmed their email.

    Defense-in-depth: the primary gate is in `Accounts.authenticate/2` which
    refuses to issue a JWT to unconfirmed users. This plug catches any edge
    case where a token is issued without confirmation (e.g., future code paths).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts.Guardian

  def init(opts), do: opts

  def call(conn, _opts) do
    case Guardian.Plug.current_resource(conn) do
      %{email_confirmed: true} ->
        conn

      %{email_confirmed: false} ->
        conn
        |> put_status(403)
        |> json(%{error: "email not confirmed"})
        |> halt()

      _ ->
        conn
    end
  end
end
