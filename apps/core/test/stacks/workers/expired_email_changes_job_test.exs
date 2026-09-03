defmodule Stacks.Workers.ExpiredEmailChangesJobTest do
  @moduledoc """
      The daily sweep that ends an email change's grace window: an account whose
      change neither address answered inside the window stops counting as
      confirmed, and `RequireConfirmedEmail` — untouched — does the rest.

      The account keeps everything. Only the flag moves, and the undo link mailed
      to its current address is the way back.
  """
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Email
  alias Stacks.Workers.ExpiredEmailChangesJob

  # A change requested `seconds_ago`, written the way the request flow writes it.
  # `pending_email_sent_at` is the clock the window is measured from, so aging it
  # is how a lapse is staged.
  defp pending_change!(email, seconds_ago) do
    user = insert(:user, email: email)

    {:ok, pending} =
      user
      |> Accounts.pending_email_changeset(%{
        pending_email: "new-#{System.unique_integer([:positive])}@thestacks.test",
        pending_email_token: Accounts.sign_email_change_token(user.id),
        pending_email_sent_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second),
        pending_email_revert_token: Accounts.sign_email_revert_token(user.id)
      })
      |> Repo.update()

    pending
  end

  defp event_count(type) do
    Repo.aggregate(from(e in "event_log", where: e.event_type == ^type), :count, prefix: "op")
  end

  test "degrades a change nobody answered, and leaves a change still inside its window alone" do
    lapsed = pending_change!("lapsed@thestacks.test", Accounts.email_change_grace_seconds() + 60)
    waiting = pending_change!("waiting@thestacks.test", 3600)

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})

    refute Repo.reload!(lapsed).email_confirmed,
           "a change nobody answered for the whole window must stop counting as confirmed"

    assert Repo.reload!(waiting).email_confirmed,
           "a change still inside its window must not be degraded"
  end

  test "leaves the pending state in place — the undo link is now the way back" do
    lapsed =
      pending_change!("still-pending@thestacks.test", Accounts.email_change_grace_seconds() + 60)

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})

    degraded = Repo.reload!(lapsed)
    refute degraded.email_confirmed
    assert degraded.pending_email == lapsed.pending_email
    assert degraded.pending_email_revert_token == lapsed.pending_email_revert_token

    assert {:ok, restored} = Email.revert_email_change(degraded.pending_email_revert_token)

    assert restored.email_confirmed,
           "the undo link must lift a degradation — it is the only affordance a gated account has"

    assert restored.email == "still-pending@thestacks.test"
  end

  test "touches nothing when no change has lapsed" do
    untouched = insert(:user, email: "no-change@thestacks.test")
    waiting = pending_change!("in-window@thestacks.test", 60)

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})

    assert Repo.reload!(untouched).email_confirmed
    assert Repo.reload!(waiting).email_confirmed
  end

  test "is idempotent — the second run degrades nobody" do
    pending_change!("twice@thestacks.test", Accounts.email_change_grace_seconds() + 60)

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})
    before = event_count("user.email_change_expired")

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})

    assert event_count("user.email_change_expired") == before,
           "a degraded account must not be degraded again every day for the rest of time"
  end

  test "records the moment trust was withdrawn, with no address in the payload" do
    lapsed = pending_change!("audited@thestacks.test", Accounts.email_change_grace_seconds() + 60)

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})

    row =
      Repo.one(
        from(e in "event_log",
          where: e.event_type == "user.email_change_expired",
          select: %{aggregate_id: e.aggregate_id, payload: e.payload}
        ),
        prefix: "op"
      )

    assert Ecto.UUID.load!(row.aggregate_id) == lapsed.id
    assert row.payload == %{}
  end

  test "emits telemetry with the degraded count" do
    pending_change!("telemetry@thestacks.test", Accounts.email_change_grace_seconds() + 60)

    parent = self()
    handler = "test-email-change-sweep-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:stacks, :accounts, :email_change_lapsed],
      fn _event, measurements, _meta, _ -> send(parent, {:lapsed, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})

    assert_receive {:lapsed, %{degraded: 1, failed: 0}}
  end

  test "a degraded account is refused a session, which is the whole point of the flag" do
    lapsed =
      pending_change!("gated@thestacks.test", Accounts.email_change_grace_seconds() + 60)

    {1, _} =
      Repo.update_all(from(u in User, where: u.id == ^lapsed.id),
        set: [password_hash: Argon2.hash_pwd_salt("password123")]
      )

    assert {:ok, _user} = Accounts.authenticate("gated@thestacks.test", "password123"),
           "precondition: this account must be able to log in before the sweep runs"

    assert :ok = perform_job(ExpiredEmailChangesJob, %{})

    assert {:error, :email_unconfirmed} =
             Accounts.authenticate("gated@thestacks.test", "password123")
  end
end
