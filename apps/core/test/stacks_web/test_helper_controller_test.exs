defmodule StacksWeb.TestHelperControllerTest do
  @moduledoc """
  Guards the test-only confirmation-token endpoint (Issue #124, Phase 3).

  This endpoint leaks an account-activation token, so the security-critical
  property under test is that it is *disabled* unless the server env flag
  `STACKS_E2E_TEST_HELPERS == "1"` is set. In production the flag is never
  set, so the route returns 404 for every request.

  `async: false` because the tests mutate a process-global environment
  variable; running serially keeps them from leaking into async tests.
  """
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  @flag "STACKS_E2E_TEST_HELPERS"

  setup do
    original = System.get_env(@flag)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(@flag)
        value -> System.put_env(@flag, value)
      end
    end)

    :ok
  end

  describe "GET /api/test/confirmation-token with the flag OFF (production posture)" do
    setup do
      System.delete_env(@flag)
      :ok
    end

    test "returns 404 and never exposes the confirmation token", %{conn: conn} do
      user =
        insert(:user,
          email: "off@example.com",
          email_confirmed: false,
          email_confirmation_token: "super-secret-token-off"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
      refute conn.resp_body =~ "super-secret-token-off"
    end

    test "returns 404 even when the flag is present but not exactly \"1\"", %{conn: conn} do
      System.put_env(@flag, "true")

      user =
        insert(:user,
          email: "notone@example.com",
          email_confirmed: false,
          email_confirmation_token: "super-secret-token-notone"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
      refute conn.resp_body =~ "super-secret-token-notone"
    end
  end

  describe "GET /api/test/confirmation-token with the flag ON" do
    setup do
      System.put_env(@flag, "1")
      :ok
    end

    test "returns 200 with ONLY the confirmation token for a seeded unconfirmed user", %{
      conn: conn
    } do
      user =
        insert(:user,
          email: "on@example.com",
          email_confirmed: false,
          email_confirmation_token: "super-secret-token-on"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      # Exact-map assertion proves the body contains the token and nothing else
      # (no email, no password_hash, no id, no other PII).
      assert json_response(conn, 200) == %{"token" => "super-secret-token-on"}
    end

    test "email lookup is case-insensitive (matches Accounts.get_user_by_email/1)", %{conn: conn} do
      insert(:user,
        email: "mixed@example.com",
        email_confirmed: false,
        email_confirmation_token: "super-secret-token-mixed"
      )

      conn = get(conn, "/api/test/confirmation-token", email: "Mixed@Example.com")

      assert json_response(conn, 200) == %{"token" => "super-secret-token-mixed"}
    end

    test "returns 404 for an unknown email", %{conn: conn} do
      conn = get(conn, "/api/test/confirmation-token", email: "nobody@example.com")

      assert conn.status == 404
    end

    test "returns 404 for a user that has no confirmation token", %{conn: conn} do
      user =
        insert(:user,
          email: "confirmed@example.com",
          email_confirmed: true,
          email_confirmation_token: nil
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
    end

    test "returns 404 when the email param is missing", %{conn: conn} do
      conn = get(conn, "/api/test/confirmation-token")

      assert conn.status == 404
    end
  end
end
