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

  # Reserved test TLD (RFC 6761) used for ALL E2E/test accounts:
  #   - suite users:       e2e-<slug>@thestacks.test   (seeds.exs / helpers.ts suiteEmail)
  #   - registration users: <prefix>-<ts>-<rand>@thestacks.test (helpers.ts uniqueEmail)
  # A real, deliverable email address can NEVER be in the `.test` TLD, so scoping
  # the lookup to this domain guarantees a real user's activation token can never
  # be leaked — even when the flag is on for a public preview carrying real users.
  @e2e_email_domain "@thestacks.test"

  @doc """
  GET /api/test/confirmation-token?email=<email>

  Returns the raw `email_confirmation_token` for the given user so the E2E
  suite can exercise the confirm-email flow without real email delivery.

  Responds `200 {"token": "<token>"}` for an existing E2E/test-domain user that
  has a confirmation token, and `404` if the email is not an E2E/test-domain
  address, the user does not exist, or the user has no token. The not-found and
  out-of-scope cases are deliberately indistinguishable (both plain 404) so the
  endpoint is not a user-enumeration oracle for real accounts.

  The response body contains ONLY the token — no email, id, password data, or
  any other PII.
  """
  def confirmation_token(conn, %{"email" => email}) when is_binary(email) do
    with true <- e2e_test_email?(email),
         %{email_confirmation_token: token} when is_binary(token) <-
           Accounts.get_user_by_email(email) do
      json(conn, %{token: token})
    else
      _ -> not_found(conn)
    end
  end

  def confirmation_token(conn, _params), do: not_found(conn)

  # Scope the endpoint to E2E/test-domain emails only. Case-insensitive to match
  # `Accounts.get_user_by_email/1`. Uses a strict domain-suffix match so
  # lookalikes such as `x@thestacks.test.evil.com` do NOT qualify.
  defp e2e_test_email?(email) do
    email
    |> String.downcase()
    |> String.ends_with?(@e2e_email_domain)
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end
end
