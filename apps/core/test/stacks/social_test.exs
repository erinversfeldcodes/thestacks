defmodule Stacks.SocialTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Social

  # ---------------------------------------------------------------------------
  # block_user/2
  # ---------------------------------------------------------------------------

  describe "block_user/2" do
    test "valid block → {:ok, block} and block row exists in DB" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:ok, block} = Social.block_user(blocker.id, blocked.id)
      assert block.blocker_id == blocker.id
      assert block.blocked_id == blocked.id

      count =
        Repo.one(
          from(b in "user_blocks",
            where: b.blocker_id == ^blocker.id and b.blocked_id == ^blocked.id,
            select: count(b.id)
          ),
          prefix: "op"
        )

      assert count == 1
    end

    test "duplicate block → returns error (unique constraint)" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      assert {:error, _reason} = Social.block_user(blocker.id, blocked.id)
    end

    test "block_user/2 emits social.user_blocked event" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _block} = Social.block_user(blocker.id, blocked.id)

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "social.user_blocked" and e.aggregate_id == ^blocker.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # unblock_user/2
  # ---------------------------------------------------------------------------

  describe "unblock_user/2" do
    test "existing block → {:ok, :unblocked} and row removed" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      assert {:ok, :unblocked} = Social.unblock_user(blocker.id, blocked.id)

      count =
        Repo.one(
          from(b in "user_blocks",
            where: b.blocker_id == ^blocker.id and b.blocked_id == ^blocked.id,
            select: count(b.id)
          ),
          prefix: "op"
        )

      assert count == 0
    end

    test "non-existent block → {:error, :not_found} or similar" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:error, _reason} = Social.unblock_user(blocker.id, blocked.id)
    end

    test "unblock_user/2 emits social.user_unblocked event" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Social.block_user(blocker.id, blocked.id)
      {:ok, :unblocked} = Social.unblock_user(blocker.id, blocked.id)

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "social.user_unblocked" and e.aggregate_id == ^blocker.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # blocked?/2
  # ---------------------------------------------------------------------------

  describe "blocked?/2" do
    test "A blocks B: blocked?(b_id, a_id) → true (bidirectional)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert true == Social.blocked?(user_b.id, user_a.id)
    end

    test "A blocks B: blocked?(a_id, b_id) → true (bidirectional)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert true == Social.blocked?(user_a.id, user_b.id)
    end

    test "no block: blocked?(a_id, b_id) → false" do
      user_a = insert(:user)
      user_b = insert(:user)

      assert false == Social.blocked?(user_a.id, user_b.id)
    end
  end

  # ---------------------------------------------------------------------------
  # blocked_by?/2
  # ---------------------------------------------------------------------------

  describe "list_blocked_users/2" do
    test "returns {[], 0} when user has no blocks" do
      user = insert(:user)
      assert {[], 0} = Social.list_blocked_users(user.id)
    end

    test "returns blocked users with display_name and blocked_at" do
      blocker = insert(:user)
      blocked = insert(:user)
      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      {results, total} = Social.list_blocked_users(blocker.id)
      assert total == 1
      assert [entry] = results
      assert entry.id == blocked.id
      assert entry.display_name == blocked.display_name
      assert %DateTime{} = entry.blocked_at
    end

    test "does not return users blocked by others" do
      user_a = insert(:user)
      user_b = insert(:user)
      user_c = insert(:user)
      {:ok, _} = Social.block_user(user_b.id, user_c.id)

      {results, total} = Social.list_blocked_users(user_a.id)
      assert total == 0
      assert results == []
    end
  end

  describe "blocked_by?/2" do
    test "A blocks B: blocked_by?(a_id, b_id) → true (A is the blocker)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert true == Social.blocked_by?(user_a.id, user_b.id)
    end

    test "A blocks B: blocked_by?(b_id, a_id) → false (B did not block A)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert false == Social.blocked_by?(user_b.id, user_a.id)
    end
  end
end
