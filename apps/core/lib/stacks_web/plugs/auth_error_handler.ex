defmodule StacksWeb.Plugs.AuthErrorHandler do
  @moduledoc "Guardian error handler — returns JSON 401/403 responses."

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, _reason}, _opts) do
    status =
      case type do
        :unauthenticated -> 401
        :unauthorized -> 403
        _ -> 401
      end

    conn
    |> put_status(status)
    |> json(%{error: Atom.to_string(type)})
    |> halt()
  end
end
