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

  test "erases expired unverified accounts and preserves confirmed + recent ones" do
    expired =
      insert(:user, email: "expired@thestacks.test", email_confirmed: false)
      |> backdate!(2 * @day)

    # Unverified but created just now — link still valid, must survive.
    recent = insert(:user, email: "recent@thestacks.test", email_confirmed: false)

    # Confirmed and old — never a reaper target.
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
end
