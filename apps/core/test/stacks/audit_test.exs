defmodule Stacks.AuditTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Audit
  alias Stacks.Audit.Entry, as: AuditEntry

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

      assert {:ok, _entry} =
               Audit.log(user.id, "test.action", resource_id: "not-a-uuid-string")
    end
  end

  describe "log_rollback/1" do
    defp attach_telemetry(events) do
      test_pid = self()
      ref = make_ref()
      handler_id = "test-rollback-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    @valid_attrs %{
      failed_sha: "deadbeefcafebabe1234567890abcdef12345678",
      target_image: "registry.fly.io/the-stacks-core:deployment-prev-1234",
      modal_prev_commit: "abc123def4567890",
      reason: "deploy SLO gate failed: error_rate > 1%",
      triggered_by: "slo-gate"
    }

    test "happy path: inserts an audit row with correct action and resource_type" do
      assert {:ok, entry} = Audit.log_rollback(@valid_attrs)

      assert entry.action == "system.rollback"
      assert entry.resource_type == "deploy"

      assert entry.metadata[:failed_sha] == @valid_attrs.failed_sha
      assert entry.metadata[:target_image] == @valid_attrs.target_image
      assert entry.metadata[:modal_prev_commit] == @valid_attrs.modal_prev_commit
      assert entry.metadata[:reason] == @valid_attrs.reason
      assert entry.metadata[:triggered_by] == @valid_attrs.triggered_by
    end

    test "resource_id is nil because a git SHA is not a UUID; SHA lives in metadata" do
      assert {:ok, entry} = Audit.log_rollback(@valid_attrs)

      assert entry.resource_id == nil
      assert entry.metadata[:failed_sha] == @valid_attrs.failed_sha
    end

    test "user_id is nil because rollback is system-initiated" do
      assert {:ok, entry} = Audit.log_rollback(@valid_attrs)
      assert entry.user_id == nil
    end

    test "triggered_by: \"slo-gate\" is preserved verbatim" do
      assert {:ok, entry} =
               Audit.log_rollback(%{@valid_attrs | triggered_by: "slo-gate"})

      assert entry.metadata[:triggered_by] == "slo-gate"
    end

    test "triggered_by: \"manual\" is preserved verbatim" do
      assert {:ok, entry} =
               Audit.log_rollback(%{@valid_attrs | triggered_by: "manual"})

      assert entry.metadata[:triggered_by] == "manual"
    end

    test "triggered_by: \"step-failure\" is preserved verbatim" do
      assert {:ok, entry} =
               Audit.log_rollback(%{@valid_attrs | triggered_by: "step-failure"})

      assert entry.metadata[:triggered_by] == "step-failure"
    end

    test "triggered_by: \"migration-failure\" is preserved verbatim" do
      assert {:ok, entry} =
               Audit.log_rollback(%{@valid_attrs | triggered_by: "migration-failure"})

      assert entry.metadata[:triggered_by] == "migration-failure"
    end

    test "modal_prev_commit: nil is accepted (vision-skip case)" do
      attrs = %{@valid_attrs | modal_prev_commit: nil}

      assert {:ok, entry} = Audit.log_rollback(attrs)

      assert Map.has_key?(entry.metadata, :modal_prev_commit)
      assert entry.metadata[:modal_prev_commit] == nil
    end

    test "emits [:stacks, :system, :rollback] telemetry once on success" do
      attach_telemetry([[:stacks, :system, :rollback]])

      assert {:ok, _entry} = Audit.log_rollback(@valid_attrs)

      assert_receive {:telemetry_event, [:stacks, :system, :rollback], measurements, metadata}

      assert measurements == %{count: 1}

      assert metadata[:failed_sha] == @valid_attrs.failed_sha
      assert metadata[:target_image] == @valid_attrs.target_image
      assert metadata[:modal_prev_commit] == @valid_attrs.modal_prev_commit
      assert metadata[:reason] == @valid_attrs.reason
      assert metadata[:triggered_by] == @valid_attrs.triggered_by

      refute_receive {:telemetry_event, [:stacks, :system, :rollback], _, _}, 50
    end

    test "does NOT emit telemetry when the underlying audit insert fails" do
      attach_telemetry([[:stacks, :system, :rollback]])

      bad_attrs = %{@valid_attrs | reason: {:not, :encodable}}

      assert {:error, _reason} = Audit.log_rollback(bad_attrs)

      refute_receive {:telemetry_event, [:stacks, :system, :rollback], _, _}, 50
    end
  end

  describe "log/3 with admin-call fields (Issue #138 Phase 1)" do
    # Phase 1 extends audit.audit_log with five additive nullable columns
    # carrying admin-call shape: endpoint, latency_ms, success, row_count,
    # operator_session_id. Stacks.Audit.log/3 must accept and persist them
    # via :opts. Until the migration + module update land, these tests fail
    # because the columns don't exist (Postgrex.Error: undefined_column).

    defp fetch_admin_columns(entry_id) do
      {:ok, %{rows: [row], columns: cols}} =
        Repo.query(
          """
          SELECT endpoint, latency_ms, success, row_count, operator_session_id
            FROM audit.audit_log
           WHERE id = $1
          """,
          [Ecto.UUID.dump!(entry_id)]
        )

      Enum.zip(cols, row) |> Enum.into(%{})
    end

    test "persists endpoint, latency_ms, success, row_count, operator_session_id from opts" do
      user = insert(:user)
      session_id = Ecto.UUID.generate()

      assert {:ok, entry} =
               Audit.log(user.id, "admin.users.by_email",
                 endpoint: "/api/admin/users/by_email",
                 latency_ms: 17,
                 success: true,
                 row_count: 1,
                 operator_session_id: session_id
               )

      cols = fetch_admin_columns(entry.id)

      assert cols["endpoint"] == "/api/admin/users/by_email"
      assert cols["latency_ms"] == 17
      assert cols["success"] == true
      assert cols["row_count"] == 1
      assert cols["operator_session_id"] == session_id
    end

    test "persists success=false for failed admin calls" do
      user = insert(:user)

      assert {:ok, entry} =
               Audit.log(user.id, "admin.users.by_email",
                 endpoint: "/api/admin/users/by_email",
                 latency_ms: 5,
                 success: false,
                 row_count: 0,
                 operator_session_id: Ecto.UUID.generate()
               )

      cols = fetch_admin_columns(entry.id)
      assert cols["success"] == false
      assert cols["row_count"] == 0
    end

    test "omitting admin-call opts leaves columns null (backwards-compatible with existing callers)" do
      user = insert(:user)

      assert {:ok, entry} = Audit.log(user.id, "user.login", resource_type: "user")

      cols = fetch_admin_columns(entry.id)
      assert cols["endpoint"] == nil
      assert cols["latency_ms"] == nil
      assert cols["success"] == nil
      assert cols["row_count"] == nil
      assert cols["operator_session_id"] == nil
    end

    test "Stacks.Audit.Entry Ecto schema declares all five new fields" do
      # Once `mix proto.sync` regenerates the Ecto schema from the updated
      # proto, __schema__(:fields) must contain the five new field atoms.
      # Until then this fails because the schema lacks them.
      fields = AuditEntry.__schema__(:fields)

      for f <- [:endpoint, :latency_ms, :success, :row_count, :operator_session_id] do
        assert f in fields,
               "expected Stacks.Audit.Entry.__schema__(:fields) to contain #{inspect(f)}, got: #{inspect(fields)}"
      end
    end

    test "result map echoes the admin-call fields back to the caller" do
      user = insert(:user)
      session_id = Ecto.UUID.generate()

      assert {:ok, entry} =
               Audit.log(user.id, "admin.audit_log",
                 endpoint: "/api/admin/audit_log",
                 latency_ms: 42,
                 success: true,
                 row_count: 7,
                 operator_session_id: session_id
               )

      assert entry.endpoint == "/api/admin/audit_log"
      assert entry.latency_ms == 42
      assert entry.success == true
      assert entry.row_count == 7
      assert entry.operator_session_id == session_id
    end
  end
end
