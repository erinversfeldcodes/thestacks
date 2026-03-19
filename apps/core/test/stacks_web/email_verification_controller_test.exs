defmodule StacksWeb.EmailVerificationControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Email

  describe "GET /api/auth/confirm/:token" do
    test "redirects to /confirm-email/success and confirms email with a valid token", %{
      conn: conn
    } do
      user = insert(:user)
      {:ok, user_with_token} = Email.send_registration_confirmation(user)
      token = user_with_token.email_confirmation_token

      conn = get(conn, "/api/auth/confirm/#{token}")

      assert redirected_to(conn) =~ "/confirm-email/success"

      updated = Core.Repo.reload!(user)
      assert updated.email_confirmed == true
    end

    test "redirects to /confirm-email/error with an invalid token", %{conn: conn} do
      conn = get(conn, "/api/auth/confirm/invalid-garbage-token")

      assert redirected_to(conn) =~ "/confirm-email/error"
    end

    test "redirects to /confirm-email/error with a valid-signature but unknown-user token", %{
      conn: conn
    } do
      fake_token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", Ecto.UUID.generate())
      conn = get(conn, "/api/auth/confirm/#{fake_token}")

      assert redirected_to(conn) =~ "/confirm-email/error"
    end
  end
end
