defmodule Stacks.Social.GroupTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Social.Group

  describe "changeset/2" do
    test "is valid with owner, name, and type" do
      owner = insert(:user)

      changeset =
        Group.changeset(%Group{}, %{
          owner_id: owner.id,
          name: "My Reading Circle",
          type: "close_friends",
          visibility: "invite_only"
        })

      assert changeset.valid?
    end

    test "is invalid without name" do
      owner = insert(:user)

      changeset =
        Group.changeset(%Group{}, %{
          owner_id: owner.id,
          type: "close_friends",
          visibility: "invite_only"
        })

      refute changeset.valid?
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown type" do
      owner = insert(:user)

      changeset =
        Group.changeset(%Group{}, %{
          owner_id: owner.id,
          name: "Bad Group",
          type: "unknown_type",
          visibility: "invite_only"
        })

      refute changeset.valid?
      assert %{type: [_ | _]} = errors_on(changeset)
    end

    test "accepts all valid type values" do
      owner = insert(:user)

      for type <- ["close_friends", "broadcast", "subscription"] do
        changeset =
          Group.changeset(%Group{}, %{
            owner_id: owner.id,
            name: "Group #{type}",
            type: type,
            visibility: "invite_only"
          })

        assert changeset.valid?, "Expected valid changeset for type=#{type}"
      end
    end
  end
end
