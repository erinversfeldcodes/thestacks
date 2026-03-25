defmodule Stacks.Social.UserBlockTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Social
  alias Stacks.Social.UserBlock

  describe "user_block_changeset/2" do
    test "is valid with blocker and blocked" do
      blocker = insert(:user)
      blocked = insert(:user)

      changeset =
        Social.user_block_changeset(%UserBlock{}, %{
          blocker_id: blocker.id,
          blocked_id: blocked.id
        })

      assert changeset.valid?
    end

    test "is invalid without blocker_id" do
      blocked = insert(:user)

      changeset =
        Social.user_block_changeset(%UserBlock{}, %{blocked_id: blocked.id})

      refute changeset.valid?
      assert %{blocker_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without blocked_id" do
      blocker = insert(:user)

      changeset =
        Social.user_block_changeset(%UserBlock{}, %{blocker_id: blocker.id})

      refute changeset.valid?
      assert %{blocked_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "unique constraint" do
    test "inserting a duplicate (same blocker + blocked) raises unique constraint error" do
      blocker = insert(:user)
      blocked = insert(:user)

      insert(:user_block, blocker: blocker, blocked: blocked)

      assert_raise Ecto.ConstraintError, fn ->
        insert(:user_block, blocker: blocker, blocked: blocked)
      end
    end
  end
end
