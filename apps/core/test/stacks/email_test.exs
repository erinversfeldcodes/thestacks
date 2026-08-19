defmodule Stacks.EmailTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Email
  alias Stacks.Workers.EmailDeliveryJob

  # The email limiter counts this user's EmailDeliveryJob rows in the last hour
  # against @per_user_hourly_limit (10), so ten jobs is the cheapest way to make
  # the next send land on the suppressed branch.
  defp saturate_email_limit(user_id) do
    for _ <- 1..10 do
      EmailDeliveryJob.new(%{
        "template" => "registration_confirmation",
        "user_id" => user_id,
        "params" => %{"token" => "saturating-the-limiter"}
      })
      |> Oban.insert!()
    end
  end

  defp enqueued_count do
    length(all_enqueued(worker: EmailDeliveryJob))
  end

  # Record the outcomes `event` reports, but only for events raised inside THIS
  # process — :telemetry handlers are global and this file is async, so a
  # sibling test's send would otherwise show up as ours.
  defp watch_outcomes(event) do
    test = self()
    id = {__MODULE__, event, System.unique_integer([:positive])}

    :telemetry.attach(
      id,
      event,
      fn ^event, measurements, metadata, ^test ->
        if self() == test, do: send(test, {:outcome, metadata[:outcome], measurements})
      end,
      test
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp outcomes do
    receive do
      {:outcome, outcome, measurements} -> [{outcome, measurements} | outcomes()]
    after
      0 -> []
    end
  end

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

  describe "send_password_reset/1 — what the platform knows about its own silence" do
    test "reports the suppression when the limiter drops a reset that was due" do
      user = insert(:user, email: "suppressed@example.com")
      saturate_email_limit(user.id)

      assert {:error, :rate_limited} = Email.send_password_reset(user.email),
             "a reset the platform swallowed reported the same :ok as one it sent"
    end

    test "a suppressed reset enqueues nothing and stores no token" do
      user = insert(:user, email: "suppressed-effects@example.com")
      saturate_email_limit(user.id)
      before = enqueued_count()

      assert {:error, :rate_limited} = Email.send_password_reset(user.email)

      assert enqueued_count() == before,
             "the limiter refused the send but a delivery job was enqueued anyway"

      assert is_nil(Core.Repo.reload!(user).password_reset_token),
             "a reset token was stored for a link that will never be sent"
    end

    test "counts the suppression on [:stacks, :auth, :password_reset] as :rate_limited" do
      user = insert(:user, email: "counted@example.com")
      saturate_email_limit(user.id)
      watch_outcomes([:stacks, :auth, :password_reset])

      Email.send_password_reset(user.email)

      assert [{:rate_limited, %{count: 1}}] = outcomes()
    end

    test "counts a delivered reset as :sent" do
      user = insert(:user, email: "counted-sent@example.com")
      watch_outcomes([:stacks, :auth, :password_reset])

      assert :ok = Email.send_password_reset(user.email)

      assert [{:sent, %{count: 1}}] = outcomes()
    end

    test "counts an address with no account as :no_account, and still answers :ok" do
      watch_outcomes([:stacks, :auth, :password_reset])

      assert :ok = Email.send_password_reset("no-such-reader@example.com"),
             "nothing was dropped, so nothing is owed — this is not an error"

      assert [{:no_account, %{count: 1}}] = outcomes()
    end
  end

  describe "send_confirmation_resend/1 — what the platform knows about its own silence" do
    test "reports the suppression when the limiter drops a link that was due" do
      user = insert(:unconfirmed_user, email: "resend-suppressed@example.com")
      saturate_email_limit(user.id)

      assert {:error, :rate_limited} = Email.send_confirmation_resend(user.email)
    end

    test "a suppressed resend enqueues nothing and leaves the old link in place" do
      user = insert(:unconfirmed_user, email: "resend-effects@example.com")
      original = user.email_confirmation_token
      saturate_email_limit(user.id)
      before = enqueued_count()

      assert {:error, :rate_limited} = Email.send_confirmation_resend(user.email)

      assert enqueued_count() == before,
             "the limiter refused the send but a delivery job was enqueued anyway"

      assert Core.Repo.reload!(user).email_confirmation_token == original,
             "the stored link was re-signed for a mail that will never be sent, " <>
               "invalidating the link the reader already has"
    end

    test "counts each outcome on [:stacks, :auth, :confirmation_resend]" do
      unconfirmed = insert(:unconfirmed_user, email: "resend-sent@example.com")
      confirmed = insert(:user, email: "resend-confirmed@example.com", email_confirmed: true)

      watch_outcomes([:stacks, :auth, :confirmation_resend])

      assert :ok = Email.send_confirmation_resend(unconfirmed.email)
      assert :ok = Email.send_confirmation_resend(confirmed.email)
      assert :ok = Email.send_confirmation_resend("no-such-reader@example.com")

      assert [{:sent, _}, {:already_confirmed, _}, {:no_account, _}] = outcomes()
    end

    test "counts an account past the renewal ceiling as :past_renewal_ceiling" do
      user = insert(:unconfirmed_user, email: "resend-capped@example.com")

      {1, _} =
        Core.Repo.update_all(
          Ecto.Query.where(Stacks.Accounts.User, [u], u.id == ^user.id),
          set: [
            created_at:
              DateTime.add(
                DateTime.utc_now(),
                -(Accounts.unverified_account_max_lifetime_seconds() + 60),
                :second
              )
          ]
        )

      watch_outcomes([:stacks, :auth, :confirmation_resend])

      assert :ok = Email.send_confirmation_resend(user.email)

      assert [{:past_renewal_ceiling, %{count: 1}}] = outcomes()
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

    test "revokes every live session so a pre-reset token cannot outlive the password" do
      user = insert(:user)
      fid = Ecto.UUID.generate()

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-before-reset",
          session_started_at: DateTime.utc_now()
        })

      refute Core.Repo.get(AuthTokenFamily, fid).revoked_at,
             "precondition: the family must start live, or this test proves nothing"

      Email.send_password_reset(user.email)
      token = Core.Repo.reload!(user).password_reset_token

      assert {:ok, _} = Email.reset_password(token, "newpassword123")

      assert Core.Repo.get(AuthTokenFamily, fid).revoked_at,
             "the session family minted before the reset is still live"

      assert {:error, :session_revoked} =
               Accounts.check_token_family(fid, "jti-before-reset", to_string(user.id)),
             "the pre-reset token still authenticates after a password reset"
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

    test "a spent reset token cannot be replayed (single-use)" do
      user = insert(:user)
      Email.send_password_reset(user.email)
      token = Core.Repo.reload!(user).password_reset_token

      assert {:ok, _} = Email.reset_password(token, "newpassword123"),
             "precondition: the first use must succeed, or the replay proves nothing"

      assert {:error, :invalid} = Email.reset_password(token, "attackerpassword456")

      final_user = Core.Repo.reload!(user)

      assert Argon2.verify_pass("newpassword123", final_user.password_hash),
             "the replayed reset overwrote the password the legitimate user set"

      refute Argon2.verify_pass("attackerpassword456", final_user.password_hash),
             "a replayed reset token set a new password — the link is not single-use"
    end
  end
end
