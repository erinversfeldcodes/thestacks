defmodule Stacks.EmailTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Email

  # A user whose confirmation token has been persisted the way
  # Accounts.register/1 does it — a signed Phoenix.Token. Both
  # send_registration_confirmation/1 and confirm_email/1 operate on this token.
  defp user_with_confirmation_token(attrs \\ []) do
    user = insert(:user, Keyword.merge([email_confirmed: false], attrs))
    token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id)

    {:ok, user} =
      user |> Ecto.Changeset.change(%{email_confirmation_token: token}) |> Core.Repo.update()

    user
  end

  describe "send_registration_confirmation/1" do
    test "enqueues an EmailDeliveryJob using the user's persisted token" do
      user = user_with_confirmation_token()

      assert {:ok, _user} = Email.send_registration_confirmation(user)

      assert_enqueued(
        worker: Stacks.Workers.EmailDeliveryJob,
        args: %{"template" => "registration_confirmation", "user_id" => user.id}
      )
    end

    test "delivers the persisted token without regenerating/overwriting it" do
      user = user_with_confirmation_token()
      original = user.email_confirmation_token

      assert {:ok, returned} = Email.send_registration_confirmation(user)

      # The async handler must never overwrite the token Accounts.register/1
      # persisted — otherwise a token already read for this user is invalidated
      # (the register↔handler race this fixes).
      assert returned.email_confirmation_token == original
      assert Core.Repo.reload!(user).email_confirmation_token == original
    end

    test "errors when the user has no confirmation token" do
      user = insert(:user, email_confirmation_token: nil)
      assert {:error, :missing_confirmation_token} = Email.send_registration_confirmation(user)
    end
  end

  describe "confirm_email/1" do
    test "sets email_confirmed to true with a valid token" do
      user = user_with_confirmation_token()
      token = user.email_confirmation_token

      assert {:ok, confirmed_user} = Email.confirm_email(token)
      assert confirmed_user.email_confirmed == true
      assert confirmed_user.email_confirmation_token == nil
    end

    test "returns {:error, :invalid} with an invalid token" do
      assert {:error, :invalid} = Email.confirm_email("not-a-valid-token")
    end

    test "returns {:error, :invalid} with a token for a non-existent user" do
      fake_token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", Ecto.UUID.generate())
      assert {:error, :invalid} = Email.confirm_email(fake_token)
    end
  end

  describe "send_password_reset/1" do
    test "returns :ok for a registered email" do
      insert(:user, email: "known@example.com")
      assert :ok = Email.send_password_reset("known@example.com")
    end

    test "returns :ok for an unregistered email (no enumeration)" do
      assert :ok = Email.send_password_reset("nobody@example.com")
    end

    test "enqueues a job for a known user" do
      user = insert(:user, email: "reset@example.com")
      Email.send_password_reset("reset@example.com")

      assert_enqueued(
        worker: Stacks.Workers.EmailDeliveryJob,
        args: %{"template" => "password_reset", "user_id" => user.id}
      )
    end

    test "does not enqueue a job for an unknown email" do
      Email.send_password_reset("ghost@example.com")
      refute_enqueued(worker: Stacks.Workers.EmailDeliveryJob)
    end
  end

  describe "reset_password/2" do
    test "updates password with a valid token" do
      user = insert(:user)
      Email.send_password_reset(user.email)

      updated_user = Core.Repo.reload!(user)
      token = updated_user.password_reset_token

      assert {:ok, _user} = Email.reset_password(token, "newpassword123")
      final_user = Core.Repo.reload!(user)
      assert Argon2.verify_pass("newpassword123", final_user.password_hash)
      assert final_user.password_reset_token == nil
    end

    test "returns {:error, :invalid} with an invalid token" do
      assert {:error, :invalid} = Email.reset_password("bad-token", "newpassword123")
    end

    test "returns {:error, :expired} with an expired token" do
      user = insert(:user)

      expired_token =
        Phoenix.Token.sign(CoreWeb.Endpoint, "password_reset", user.id,
          signed_at: System.system_time(:second) - 90_000
        )

      assert {:error, :expired} = Email.reset_password(expired_token, "newpassword123")
    end

    test "returns a changeset error when new password is too short" do
      user = insert(:user)
      Email.send_password_reset(user.email)

      updated_user = Core.Repo.reload!(user)
      token = updated_user.password_reset_token

      assert {:error, changeset} = Email.reset_password(token, "short")
      assert %{password: [_ | _]} = errors_on(changeset)
    end

    test "clears reset token after successful password update" do
      user = insert(:user)
      Email.send_password_reset(user.email)

      updated_user = Core.Repo.reload!(user)
      token = updated_user.password_reset_token

      assert {:ok, _user} = Email.reset_password(token, "newpassword123")
      final_user = Core.Repo.reload!(user)
      assert final_user.password_reset_token == nil
      assert final_user.password_reset_sent_at == nil
    end
  end
end
