defmodule Stacks.Workers.ExpiredInvitesSweepJobTest do
  @moduledoc """
      The sweep is the ONLY retention path for an unredeemed invitation.

      That matters because an unredeemed invitation names someone who never became a
      user: its `invited_email` belongs to a person with no account, who therefore
      cannot ask for erasure. Nothing else reaches the row — `delete_user_data/1`
      scrubs invitations naming an existing user, and a never-user has none.

      The case these tests were written for: `expires_at` is NULLABLE and a null means
      "never expires", so a guard of `not is_nil(expires_at)` silently excluded exactly
      the rows with no other way out.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.InviteCode
  alias Stacks.Accounts.Invites
  alias Stacks.Workers.ExpiredInvitesSweepJob

  @beyond_retention -200 * 24 * 3600
  @within_retention -3 * 24 * 3600

  defp issue(owner, attrs) do
    {:ok, %{invite: invite}} =
      Invites.issue(owner, Map.merge(%{"invited_email" => "mara@example.test"}, attrs))

    invite
  end

  defp age(invite, seconds, field) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)
    Repo.update_all(from(i in InviteCode, where: i.id == ^invite.id), set: [{field, at}])
    invite
  end

  defp swept?(invite) do
    :ok = ExpiredInvitesSweepJob.perform(%Oban.Job{})
    is_nil(Repo.get(InviteCode, invite.id))
  end

  describe "perform/1" do
    test "sweeps an invitation whose expiry is long past" do
      owner = insert(:user)

      invite =
        owner
        |> issue(%{"expires_in_days" => 1})
        |> age(@beyond_retention, :expires_at)

      assert swept?(invite)
    end

    test "sweeps a NEVER-EXPIRING invitation once it is old enough" do
      # The case the original guard excluded. A null expiry is reachable through
      # `Invites.expires_at_from/1` on an explicit `"expires_in_days": null`, and such
      # a row has no other retention path at all.
      owner = insert(:user)

      invite =
        owner
        |> issue(%{"expires_in_days" => nil})
        |> age(@beyond_retention, :created_at)

      assert Repo.get(InviteCode, invite.id).expires_at == nil
      assert swept?(invite), "a never-expiring invitation must still age out"
    end

    test "keeps a never-expiring invitation that is still within retention" do
      owner = insert(:user)

      invite =
        owner
        |> issue(%{"expires_in_days" => nil})
        |> age(@within_retention, :created_at)

      refute swept?(invite)
    end

    test "keeps an invitation that has been redeemed, however old" do
      owner = insert(:user)
      redeemer = insert(:user)

      invite =
        owner
        |> issue(%{"expires_in_days" => 1})
        |> age(@beyond_retention, :expires_at)

      Repo.update_all(
        from(i in InviteCode, where: i.id == ^invite.id),
        set: [redeemed_at: DateTime.utc_now(), redeemed_by_id: redeemer.id, use_count: 1]
      )

      refute swept?(invite), "beta history is kept deliberately once an invite was used"
    end
  end
end
