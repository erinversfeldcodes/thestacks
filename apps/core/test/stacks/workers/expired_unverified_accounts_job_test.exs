defmodule Stacks.Workers.ExpiredUnverifiedAccountsJobTest do
  @moduledoc """
  The daily reaper for abandoned signups: accounts that never confirmed their
  email and whose 24h confirmation link has expired are erased via the full
  GDPR path; everything else is left alone.
  """
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Workers.ExpiredUnverifiedAccountsJob

  @day 24 * 60 * 60

  defp backdate!(user, seconds_ago) do
    ts = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    {1, _} = Repo.update_all(from(u in User, where: u.id == ^user.id), set: [created_at: ts])
    user
  end

  defp abandoned_signup!(email, seconds_ago) do
    user = insert(:unconfirmed_user, email: email)
    signed_at = System.os_time(:second) - seconds_ago

    token =
      Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id, signed_at: signed_at)

    {1, _} =
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [email_confirmation_token: token]
      )

    backdate!(user, seconds_ago)
  end

  test "erases expired unverified accounts and preserves confirmed + recent ones" do
    expired =
      insert(:user, email: "expired@thestacks.test", email_confirmed: false)
      |> backdate!(2 * @day)

    recent = insert(:user, email: "recent@thestacks.test", email_confirmed: false)

    confirmed_old =
      insert(:user, email: "confirmed@thestacks.test", email_confirmed: true)
      |> backdate!(2 * @day)

    assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})

    assert Accounts.get_user(expired.id) == nil, "expired unverified account must be erased"
    assert Accounts.get_user(recent.id), "recent unverified account must survive"
    assert Accounts.get_user(confirmed_old.id), "confirmed account must survive"
  end

  test "writes a GDPR erasure audit row for each reaped account" do
    insert(:user, email: "reaped-audit@thestacks.test", email_confirmed: false)
    |> backdate!(2 * @day)

    assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})

    audit_count =
      Repo.aggregate(
        from(a in "audit_log", where: a.action == "user.data_deleted"),
        :count,
        prefix: "audit"
      )

    assert audit_count == 1
  end

  test "emits telemetry with the erased count" do
    insert(:user, email: "reaped-telemetry@thestacks.test", email_confirmed: false)
    |> backdate!(2 * @day)

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "test-reaper-#{inspect(ref)}",
      [:stacks, :accounts, :unverified_reaped],
      fn _event, measurements, _meta, _ -> send(parent, {:reaped, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-reaper-#{inspect(ref)}") end)

    assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})

    assert_receive {:reaped, %{erased: 1, failed: 0}}
  end

  test "is a no-op when there are no expired unverified accounts" do
    insert(:user, email: "fresh@thestacks.test", email_confirmed: false)

    assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})
    assert Accounts.get_user_by_email("fresh@thestacks.test")
  end

  describe "the resend interplay (Issue #373)" do
    test "a resend rescues an account the reaper was about to erase" do
      user = abandoned_signup!("about-to-be-reaped@thestacks.test", 2 * @day)

      assert user.id in Accounts.expired_unverified_ids(),
             "precondition: this account's link is dead, so it is a reaper target"

      assert :ok = Stacks.Email.send_confirmation_resend(user.email)

      refute user.id in Accounts.expired_unverified_ids(),
             "asking for a fresh link must take the account off the reaper's list"

      assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})

      assert Accounts.get_user(user.id),
             "the account behind a link we just sent must still be there when it is clicked"

      token = Repo.reload!(user).email_confirmation_token
      assert {:ok, confirmed} = Stacks.Email.confirm_email(token)
      assert confirmed.email_confirmed
    end

    test "an account that never asks for a fresh link is still erased" do
      user = abandoned_signup!("truly-abandoned@thestacks.test", 2 * @day)

      assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})

      refute Accounts.get_user(user.id),
             "an abandoned signup with a dead link must still be reaped"
    end

    test "the reprieve is one TTL from the resend, not forever" do
      user = abandoned_signup!("resent-then-abandoned@thestacks.test", 2 * @day)
      assert :ok = Stacks.Email.send_confirmation_resend(user.email)
      refute user.id in Accounts.expired_unverified_ids()

      stale =
        Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id,
          signed_at: System.os_time(:second) - (Accounts.unverified_account_ttl_seconds() + 60)
        )

      {1, _} =
        Repo.update_all(from(u in User, where: u.id == ^user.id),
          set: [email_confirmation_token: stale]
        )

      assert user.id in Accounts.expired_unverified_ids(),
             "once the reissued link expires in its turn, the account is a target again"

      assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})
      refute Accounts.get_user(user.id)
    end

    test "past the absolute cap, no further link is issued and the account is reaped" do
      user =
        abandoned_signup!(
          "renewed-forever@thestacks.test",
          Accounts.unverified_account_max_lifetime_seconds() + 60
        )

      before = Repo.reload!(user).email_confirmation_token

      assert :ok = Stacks.Email.send_confirmation_resend(user.email)

      assert Repo.reload!(user).email_confirmation_token == before,
             "no new link may be minted for an account past the cap"

      assert Repo.all(Oban.Job) == [], "and nothing may be sent"

      assert user.id in Accounts.expired_unverified_ids(),
             "the resend must not have rescued it"

      assert :ok = perform_job(ExpiredUnverifiedAccountsJob, %{})
      refute Accounts.get_user(user.id)
    end

    test "just inside the cap, a link is still issued" do
      user =
        abandoned_signup!(
          "still-in-time@thestacks.test",
          Accounts.unverified_account_max_lifetime_seconds() - 3600
        )

      before = Repo.reload!(user).email_confirmation_token

      assert :ok = Stacks.Email.send_confirmation_resend(user.email)

      refute Repo.reload!(user).email_confirmation_token == before
      refute user.id in Accounts.expired_unverified_ids()
    end

    test "the reaper spares exactly the accounts whose link would still confirm" do
      live = abandoned_signup!("link-still-good@thestacks.test", 2 * @day)
      dead = abandoned_signup!("link-long-dead@thestacks.test", 2 * @day)

      fresh = Accounts.sign_confirmation_token(live.id)

      {1, _} =
        Repo.update_all(from(u in User, where: u.id == ^live.id),
          set: [email_confirmation_token: fresh]
        )

      reaping = Accounts.expired_unverified_ids()

      assert dead.id in reaping
      refute live.id in reaping

      assert {:ok, _} = Stacks.Email.confirm_email(fresh)
      assert {:error, :invalid} = Stacks.Email.confirm_email(dead.email_confirmation_token)
    end
  end
end
