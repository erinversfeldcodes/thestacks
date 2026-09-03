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

  # An account mid-change, written the way the request flow writes it.
  defp user_with_pending_change(attrs \\ []) do
    user = insert(:user, Keyword.merge([email: "old@thestacks.test"], attrs))

    {:ok, pending} =
      user
      |> Accounts.pending_email_changeset(%{
        pending_email: "new@thestacks.test",
        pending_email_token: Accounts.sign_email_change_token(user.id),
        pending_email_sent_at: DateTime.utc_now(),
        pending_email_revert_token: Accounts.sign_email_revert_token(user.id)
      })
      |> Core.Repo.update()

    pending
  end

  describe "send_email_change_pair/1" do
    test "mails the new address a confirmation and the old address an undo link" do
      user = user_with_pending_change()

      assert {:ok, _user} = Email.send_email_change_pair(user)

      jobs = all_enqueued(worker: EmailDeliveryJob)
      templates = Enum.map(jobs, & &1.args["template"]) |> Enum.sort()

      assert templates == ["email_change_confirmation", "email_change_notice"]

      confirmation = Enum.find(jobs, &(&1.args["template"] == "email_change_confirmation"))
      notice = Enum.find(jobs, &(&1.args["template"] == "email_change_notice"))

      assert confirmation.args["params"]["token"] == user.pending_email_token
      assert notice.args["params"]["token"] == user.pending_email_revert_token
    end

    test "refuses rather than recording a change whose letters cannot be sent" do
      user = user_with_pending_change()
      saturate_email_limit(user.id)
      watch_outcomes([:stacks, :auth, :email_change])
      before = enqueued_count()

      assert {:error, :rate_limited} = Email.send_email_change_pair(user)

      assert enqueued_count() == before
      assert [{:rate_limited, _}] = outcomes()
    end
  end

  describe "confirm_email_change/1" do
    test "swaps the pending address in and clears the whole quartet" do
      user = user_with_pending_change()

      assert {:ok, updated} = Email.confirm_email_change(user.pending_email_token)

      assert updated.email == "new@thestacks.test"
      assert updated.email_confirmed
      assert updated.pending_email == nil
      assert updated.pending_email_token == nil
      assert updated.pending_email_sent_at == nil
      assert updated.pending_email_revert_token == nil
    end

    test "a confirmed change kills the undo link that was mailed with it" do
      user = user_with_pending_change()
      revert_token = user.pending_email_revert_token

      assert {:ok, _} = Email.confirm_email_change(user.pending_email_token)

      assert {:error, :invalid} = Email.revert_email_change(revert_token)
      assert Core.Repo.reload!(user).email == "new@thestacks.test"
    end

    test "a confirmation link cannot be replayed" do
      user = user_with_pending_change()
      token = user.pending_email_token

      assert {:ok, _} = Email.confirm_email_change(token),
             "precondition: the first use must succeed, or the replay proves nothing"

      assert {:error, :invalid} = Email.confirm_email_change(token)
    end

    test "a link signed for one account cannot confirm another's pending change" do
      user = user_with_pending_change()
      stranger = insert(:user, email: "stranger@thestacks.test")

      foreign_token = Accounts.sign_email_change_token(stranger.id)

      assert {:error, :invalid} = Email.confirm_email_change(foreign_token)
      assert Core.Repo.reload!(user).email == "old@thestacks.test"
    end

    test "a link older than the grace window no longer confirms" do
      user = user_with_pending_change()

      stale =
        Phoenix.Token.sign(CoreWeb.Endpoint, "email_change", user.id,
          signed_at: System.system_time(:second) - (Accounts.email_change_grace_seconds() + 60)
        )

      {:ok, _} =
        user
        |> Accounts.pending_email_changeset(%{pending_email_token: stale})
        |> Core.Repo.update()

      assert {:error, :invalid} = Email.confirm_email_change(stale)
      assert Core.Repo.reload!(user).email == "old@thestacks.test"
    end

    test "an undo token cannot be replayed as a confirmation" do
      user = user_with_pending_change()

      assert {:error, :invalid} = Email.confirm_email_change(user.pending_email_revert_token)
      assert Core.Repo.reload!(user).email == "old@thestacks.test"
    end

    test "counts confirmed and dead links apart" do
      user = user_with_pending_change()
      watch_outcomes([:stacks, :auth, :email_change])

      {:ok, _} = Email.confirm_email_change(user.pending_email_token)
      {:error, :invalid} = Email.confirm_email_change("not-a-token")

      counted = outcomes() |> Enum.map(fn {outcome, _} -> outcome end) |> Enum.sort()
      assert counted == [:confirmed, :invalid_confirm]
    end
  end

  describe "revert_email_change/1" do
    test "clears the quartet, leaves the address alone, and restores confirmed status" do
      user = user_with_pending_change(email_confirmed: false)

      assert {:ok, updated} = Email.revert_email_change(user.pending_email_revert_token)

      assert updated.email == "old@thestacks.test"
      assert updated.email_confirmed, "the click proves control of the address on the row"
      assert updated.pending_email == nil
      assert updated.pending_email_token == nil
      assert updated.pending_email_sent_at == nil
      assert updated.pending_email_revert_token == nil
    end

    test "invalidates the pending confirmation — the hijack heals itself" do
      user = user_with_pending_change()
      confirmation_token = user.pending_email_token

      assert {:ok, _} = Email.revert_email_change(user.pending_email_revert_token)

      assert {:error, :invalid} = Email.confirm_email_change(confirmation_token),
             "the confirmation link outlived the undo that was supposed to cancel it"

      assert Core.Repo.reload!(user).email == "old@thestacks.test"
    end

    test "revokes every live session, because the change may not have been the reader's" do
      user = user_with_pending_change()
      fid = Ecto.UUID.generate()

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-before-revert",
          session_started_at: DateTime.utc_now()
        })

      refute Core.Repo.get(AuthTokenFamily, fid).revoked_at,
             "precondition: the family must start live, or this test proves nothing"

      assert {:ok, _} = Email.revert_email_change(user.pending_email_revert_token)

      assert {:error, :session_revoked} =
               Accounts.check_token_family(fid, "jti-before-revert", to_string(user.id)),
             "the session that requested the change still authenticates after the undo"
    end

    test "an undo link outlives the grace window" do
      user = user_with_pending_change()

      aged =
        Phoenix.Token.sign(CoreWeb.Endpoint, "email_change_revert", user.id,
          signed_at: System.system_time(:second) - (Accounts.email_change_grace_seconds() + 60)
        )

      {:ok, user} =
        user
        |> Accounts.pending_email_changeset(%{pending_email_revert_token: aged})
        |> Core.Repo.update()

      assert {:ok, _} = Email.revert_email_change(user.pending_email_revert_token),
             "a degraded account's only way back must still work after the window"
    end

    test "an undo link older than its own life does not work" do
      user = user_with_pending_change()

      expired =
        Phoenix.Token.sign(CoreWeb.Endpoint, "email_change_revert", user.id,
          signed_at: System.system_time(:second) - (Accounts.email_revert_link_seconds() + 60)
        )

      {:ok, user} =
        user
        |> Accounts.pending_email_changeset(%{pending_email_revert_token: expired})
        |> Core.Repo.update()

      assert {:error, :invalid} = Email.revert_email_change(user.pending_email_revert_token)
    end

    test "a confirmation token cannot be replayed as an undo" do
      user = user_with_pending_change()

      assert {:error, :invalid} = Email.revert_email_change(user.pending_email_token)
      assert Core.Repo.reload!(user).pending_email == "new@thestacks.test"
    end
  end
end
