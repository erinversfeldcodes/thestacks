defmodule Stacks.Social.GroupInvitationTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Social
  alias Stacks.Social.GroupInvitation

  describe "group_invitation_changeset/2" do
    test "is valid with required fields" do
      group = insert(:group)
      inviter = insert(:user)
      invitee = insert(:user)

      changeset =
        Social.group_invitation_changeset(%GroupInvitation{}, %{
          group_id: group.id,
          invited_by_id: inviter.id,
          invited_user_id: invitee.id,
          status: "pending"
        })

      assert changeset.valid?
    end

    test "is invalid without group_id" do
      changeset =
        Social.group_invitation_changeset(%GroupInvitation{}, %{
          invited_by_id: Ecto.UUID.generate(),
          invited_user_id: Ecto.UUID.generate(),
          status: "pending"
        })

      refute changeset.valid?
      assert %{group_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without invited_by_id" do
      changeset =
        Social.group_invitation_changeset(%GroupInvitation{}, %{
          group_id: Ecto.UUID.generate(),
          invited_user_id: Ecto.UUID.generate(),
          status: "pending"
        })

      refute changeset.valid?
      assert %{invited_by_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without invited_user_id" do
      changeset =
        Social.group_invitation_changeset(%GroupInvitation{}, %{
          group_id: Ecto.UUID.generate(),
          invited_by_id: Ecto.UUID.generate(),
          status: "pending"
        })

      refute changeset.valid?
      assert %{invited_user_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown status" do
      changeset =
        Social.group_invitation_changeset(%GroupInvitation{}, %{
          group_id: Ecto.UUID.generate(),
          invited_by_id: Ecto.UUID.generate(),
          invited_user_id: Ecto.UUID.generate(),
          status: "maybe"
        })

      refute changeset.valid?
      assert %{status: [_ | _]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- ~w(pending accepted declined) do
        changeset =
          Social.group_invitation_changeset(%GroupInvitation{}, %{
            group_id: Ecto.UUID.generate(),
            invited_by_id: Ecto.UUID.generate(),
            invited_user_id: Ecto.UUID.generate(),
            status: status
          })

        assert changeset.valid?, "expected valid for status=#{status}"
      end
    end
  end

  describe "DB constraint smoke test" do
    test "persists a valid invitation" do
      invitation = insert(:group_invitation)
      assert invitation.id
      assert invitation.status == "pending"
    end
  end
end
