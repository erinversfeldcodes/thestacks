defmodule Stacks.Admin.DataTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Admin.Data

  describe "get_user_by_email/1" do
    test "returns {:ok, user_map} for existing user" do
      user = insert(:user, email: "findme@example.com")
      assert {:ok, user_map} = Data.get_user_by_email("findme@example.com")
      assert user_map.id == user.id
      assert user_map.email == "findme@example.com"
    end

    test "user_map does not include password_hash or token fields" do
      insert(:user, email: "safe@example.com")
      {:ok, user_map} = Data.get_user_by_email("safe@example.com")
      refute Map.has_key?(user_map, :password_hash)
      refute Map.has_key?(user_map, :password_reset_token)
      refute Map.has_key?(user_map, :email_confirmation_token)
    end

    test "returns {:error, :not_found} for unknown email" do
      assert {:error, :not_found} = Data.get_user_by_email("nobody@example.com")
    end

    test "is case-insensitive" do
      insert(:user, email: "mixed@example.com")
      assert {:ok, user_map} = Data.get_user_by_email("MIXED@EXAMPLE.COM")
      assert user_map.email == "mixed@example.com"
    end
  end

  describe "get_user_by_id/1" do
    test "returns {:ok, user_map} for existing user" do
      user = insert(:user)
      assert {:ok, user_map} = Data.get_user_by_id(user.id)
      assert user_map.id == user.id
    end

    test "returns {:error, :not_found} for unknown id" do
      assert {:error, :not_found} = Data.get_user_by_id(Ecto.UUID.generate())
    end
  end

  describe "list_audit_log/3" do
    test "returns entries within date range" do
      user = insert(:user)

      {:ok, _} =
        Stacks.Audit.log(user.id, "test.action",
          resource_type: "test",
          metadata: %{info: "test"}
        )

      from_dt = DateTime.add(DateTime.utc_now(), -5, :minute)
      to_dt = DateTime.add(DateTime.utc_now(), 5, :minute)

      assert {:ok, entries} = Data.list_audit_log(user.id, from_dt, to_dt)
      assert entries != []
    end

    test "returns {:error, :invalid_params} for nil user_id" do
      from_dt = DateTime.add(DateTime.utc_now(), -5, :minute)
      to_dt = DateTime.add(DateTime.utc_now(), 5, :minute)

      assert {:error, :invalid_params} = Data.list_audit_log(nil, from_dt, to_dt)
    end

    test "returns empty list when no entries match" do
      user = insert(:user)
      from_dt = DateTime.add(DateTime.utc_now(), -10, :minute)
      to_dt = DateTime.add(DateTime.utc_now(), -5, :minute)

      assert {:ok, []} = Data.list_audit_log(user.id, from_dt, to_dt)
    end

    test "respects from/to bounds (excludes entries outside)" do
      user = insert(:user)

      # Insert an entry now
      {:ok, _} =
        Stacks.Audit.log(user.id, "in_range.action",
          resource_type: "test",
          metadata: %{}
        )

      # Query for a range in the past that excludes the entry we just created
      from_dt = DateTime.add(DateTime.utc_now(), -60, :minute)
      to_dt = DateTime.add(DateTime.utc_now(), -30, :minute)

      assert {:ok, entries} = Data.list_audit_log(user.id, from_dt, to_dt)
      refute Enum.any?(entries, fn e -> e.action == "in_range.action" end)
    end

    test "entries have expected fields (no metadata)" do
      user = insert(:user)

      {:ok, _} =
        Stacks.Audit.log(user.id, "field.check",
          resource_type: "test",
          endpoint: "/api/admin/test",
          latency_ms: 42,
          success: true,
          row_count: 1,
          metadata: %{secret: "should_not_appear"}
        )

      from_dt = DateTime.add(DateTime.utc_now(), -5, :minute)
      to_dt = DateTime.add(DateTime.utc_now(), 5, :minute)

      {:ok, entries} = Data.list_audit_log(user.id, from_dt, to_dt)
      entry = Enum.find(entries, fn e -> e.action == "field.check" end)

      assert entry != nil
      assert Map.has_key?(entry, :id)
      assert Map.has_key?(entry, :user_id)
      assert Map.has_key?(entry, :action)
      assert Map.has_key?(entry, :resource_type)
      assert Map.has_key?(entry, :occurred_at)
      refute Map.has_key?(entry, :metadata)
    end

    test "user_id in result is a UUID string (not binary)" do
      user = insert(:user)

      {:ok, _} =
        Stacks.Audit.log(user.id, "uuid.check",
          resource_type: "test",
          metadata: %{}
        )

      from_dt = DateTime.add(DateTime.utc_now(), -5, :minute)
      to_dt = DateTime.add(DateTime.utc_now(), 5, :minute)

      {:ok, entries} = Data.list_audit_log(user.id, from_dt, to_dt)
      entry = Enum.find(entries, fn e -> e.action == "uuid.check" end)
      assert entry != nil
      # Should be a formatted UUID string, not binary bytes
      assert is_binary(entry.user_id)
      assert String.length(entry.user_id) == 36
      assert entry.user_id =~ ~r/^[0-9a-f-]{36}$/
    end
  end

  describe "platform_stats/0" do
    test "returns map with user, book, bookshelf, placement, listing counts" do
      assert {:ok, stats} = Data.platform_stats()
      assert Map.has_key?(stats, :users)
      assert Map.has_key?(stats, :books)
      assert Map.has_key?(stats, :bookshelves)
      assert Map.has_key?(stats, :placements)
      assert Map.has_key?(stats, :listings)
      assert is_integer(stats.users)
    end

    test "counts increase when records are inserted" do
      {:ok, before_stats} = Data.platform_stats()
      insert(:user)
      {:ok, after_stats} = Data.platform_stats()
      assert after_stats.users == before_stats.users + 1
    end
  end
end
