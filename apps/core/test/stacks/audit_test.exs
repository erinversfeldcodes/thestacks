defmodule Stacks.AuditTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Audit

  describe "log/3" do
    test "inserts an audit entry successfully" do
      user = insert(:user)

      assert {:ok, entry} =
               Audit.log(user.id, "test.action", resource_type: "user", resource_id: user.id)

      assert entry.action == "test.action"
      assert entry.user_id == user.id
    end

    test "hashes the IP address before storing" do
      user = insert(:user)
      assert {:ok, entry} = Audit.log(user.id, "test.action", ip: "192.168.1.1")
      assert entry.ip_address != nil
      assert entry.ip_address != "192.168.1.1"
      assert String.length(entry.ip_address) == 64
    end

    test "stores metadata in the entry" do
      user = insert(:user)
      meta = %{"key" => "value"}
      assert {:ok, entry} = Audit.log(user.id, "test.action", metadata: meta)
      assert entry.metadata == meta
    end

    test "works with nil user_id for system actions" do
      assert {:ok, entry} = Audit.log(nil, "system.action", resource_type: "system")
      assert entry.user_id == nil
      assert entry.action == "system.action"
    end

    test "works without optional fields" do
      user = insert(:user)
      assert {:ok, _entry} = Audit.log(user.id, "minimal.action")
    end

    test "handles non-UUID resource_id gracefully (encode_uuid returns nil)" do
      user = insert(:user)
      # Passing a non-UUID string as resource_id hits encode_uuid's :error branch
      assert {:ok, _entry} =
               Audit.log(user.id, "test.action", resource_id: "not-a-uuid-string")
    end
  end
end
