defmodule StacksWeb.Plugs.AuthErrorHandler do
  @moduledoc """
      Guardian error handler — returns JSON 401/403 responses.

      ⛔ A 401 SAYS WHETHER A SESSION WAS REFUSED OR NEVER PRESENTED, and that
      distinction is the whole reason this module is more than three lines.

      The SPA asks `GET /api/auth/me` at boot and acts on the answer. A reader
      whose session has expired must be TOLD — "we closed your session" — and a
      reader who was never signed in must not be, because an unexplained
      sign-out is indistinguishable from a deliberate one, which is the defect
      that made the private-browsing auth bug expensive to diagnose.

      ⚠️ The client cannot make this distinction itself. The session cookie is
      `HttpOnly`, so the page cannot see whether the browser sent one. The
      server can: `SessionCookie` records a rejected cookie on the conn, and
      this reads it.
  """

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
    |> json(%{error: error_token(conn, type)})
    |> halt()
  end

  # A session that WAS presented and refused is reported as such; anything else
  # keeps the Guardian type it already reported, so no existing client sees a
  # changed token for a case whose meaning has not changed.
  defp error_token(conn, :unauthenticated) do
    case conn.private[:stacks_session_cookie_rejected] do
      nil -> "unauthenticated"
      _rejected -> "session_expired"
    end
  end

  defp error_token(_conn, type), do: Atom.to_string(type)
end
