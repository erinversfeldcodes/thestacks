defmodule StacksWeb.EmailVerificationControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  describe "GET /api/auth/confirm/:token" do
    test "redirects to /confirm-email/success and confirms email with a valid token", %{
      conn: conn
    } do
      user = insert(:user, email_confirmed: false)
      token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id)

      {:ok, user} =
        user |> Ecto.Changeset.change(%{email_confirmation_token: token}) |> Core.Repo.update()

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

  describe "the email-change links" do
    setup do
      user = insert(:user, email: "old@thestacks.test")

      {:ok, pending} =
        user
        |> Stacks.Accounts.pending_email_changeset(%{
          pending_email: "new@thestacks.test",
          pending_email_token: Stacks.Accounts.sign_email_change_token(user.id),
          pending_email_sent_at: DateTime.utc_now(),
          pending_email_revert_token: Stacks.Accounts.sign_email_revert_token(user.id)
        })
        |> Core.Repo.update()

      %{user: pending}
    end

    test "confirming lands on the confirmed page and moves the address", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, "/api/auth/confirm-email-change/#{user.pending_email_token}")

      assert redirected_to(conn) =~ "/confirm-email/change-confirmed"
      assert Core.Repo.reload!(user).email == "new@thestacks.test"
    end

    test "reverting lands on the reverted page and leaves the address alone", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, "/api/auth/revert-email-change/#{user.pending_email_revert_token}")

      assert redirected_to(conn) =~ "/confirm-email/change-reverted"

      restored = Core.Repo.reload!(user)
      assert restored.email == "old@thestacks.test"
      assert restored.pending_email == nil
    end

    test "every failure of either endpoint lands on ONE page — nothing to enumerate with", %{
      conn: conn,
      user: user
    } do
      stranger_token = Stacks.Accounts.sign_email_change_token(Ecto.UUID.generate())

      expired =
        Phoenix.Token.sign(CoreWeb.Endpoint, "email_change", user.id,
          signed_at:
            System.system_time(:second) - (Stacks.Accounts.email_change_grace_seconds() + 60)
        )

      failures = [
        get(conn, "/api/auth/confirm-email-change/not-a-token"),
        get(conn, "/api/auth/confirm-email-change/#{stranger_token}"),
        get(conn, "/api/auth/confirm-email-change/#{expired}"),
        # a revert token replayed as a confirmation, and the reverse
        get(conn, "/api/auth/confirm-email-change/#{user.pending_email_revert_token}"),
        get(conn, "/api/auth/revert-email-change/not-a-token"),
        get(conn, "/api/auth/revert-email-change/#{user.pending_email_token}")
      ]

      for failed <- failures do
        assert failed.status == 302
        assert redirected_to(failed) =~ "/confirm-email/change-error"
      end

      untouched = Core.Repo.reload!(user)
      assert untouched.email == "old@thestacks.test"
      assert untouched.pending_email == "new@thestacks.test"
    end

    test "neither endpoint needs a session — they are clicked from a mail client", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, "/api/auth/confirm-email-change/#{user.pending_email_token}")

      refute conn.status == 401
      assert redirected_to(conn) =~ "/confirm-email/change-confirmed"
    end
  end
end
