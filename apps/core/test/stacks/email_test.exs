defmodule Stacks.EmailTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Email

  describe "send_registration_confirmation/1" do
    test "enqueues an EmailDeliveryJob for the user" do
      user = insert(:user)

      assert {:ok, _user} = Email.send_registration_confirmation(user)

      assert_enqueued(
        worker: Stacks.Workers.EmailDeliveryJob,
        args: %{"template" => "registration_confirmation", "user_id" => user.id}
      )
    end

    test "stores the confirmation token on the user" do
      user = insert(:user)
      assert {:ok, updated_user} = Email.send_registration_confirmation(user)
      assert updated_user.email_confirmation_token != nil
    end
  end

  describe "confirm_email/1" do
    test "sets email_confirmed to true with a valid token" do
      user = insert(:user)
      {:ok, user_with_token} = Email.send_registration_confirmation(user)

      token = user_with_token.email_confirmation_token

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
