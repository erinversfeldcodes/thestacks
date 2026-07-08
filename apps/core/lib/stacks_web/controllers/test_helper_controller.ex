defmodule StacksWeb.TestHelperController do
  @moduledoc """
  Test-only endpoints used by the E2E suite (Issue #124).

  These endpoints are UNAUTHENTICATED by design — the E2E suite calls them
  before it has a session (e.g. to drive the confirm-email flow without real
  email delivery). The sole gate is `StacksWeb.Plugs.E2ETestHelper`, which
  requires the `STACKS_E2E_TEST_HELPERS=1` server flag and returns 404
  otherwise. This controller therefore assumes the flag is on; it must never
  be routed without that plug in front of it.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts

  @doc """
  GET /api/test/confirmation-token?email=<email>

  Returns the raw `email_confirmation_token` for the given user so the E2E
  suite can exercise the confirm-email flow without real email delivery.

  Responds `200 {"token": "<token>"}` for an existing user that has a
  confirmation token, and `404` if the user does not exist or has no token.

  The response body contains ONLY the token — no email, id, password data, or
  any other PII.
  """
  def confirmation_token(conn, %{"email" => email}) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      %{email_confirmation_token: token} when is_binary(token) ->
        json(conn, %{token: token})

      _ ->
        not_found(conn)
    end
  end

  def confirmation_token(conn, _params), do: not_found(conn)

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end
end
