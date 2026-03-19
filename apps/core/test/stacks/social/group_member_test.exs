defmodule Stacks.Social.GroupMemberTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Social.GroupMember

  describe "changeset/2" do
    test "is valid with group, user, and role" do
      group = insert(:group)
      user = insert(:user)

      changeset =
        GroupMember.changeset(%GroupMember{}, %{
          group_id: group.id,
          user_id: user.id,
          role: "member"
        })

      assert changeset.valid?
    end

    test "is invalid with an unknown role" do
      group = insert(:group)
      user = insert(:user)

      changeset =
        GroupMember.changeset(%GroupMember{}, %{
          group_id: group.id,
          user_id: user.id,
          role: "supreme_overlord"
        })

      refute changeset.valid?
      assert %{role: [_ | _]} = errors_on(changeset)
    end
  end

  describe "unique constraint" do
    test "inserting a duplicate (same group + user) raises unique constraint error" do
      group = insert(:group)
      user = insert(:user)

      insert(:group_member, group: group, user: user)

      assert_raise Ecto.ConstraintError, fn ->
        insert(:group_member, group: group, user: user)
      end
    end
  end
end
