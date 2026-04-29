defmodule Stacks.AuditTest do
  use Core.DataCase, async: false

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

  describe "log_rollback/1" do
    # Helper: subscribe the test process to a list of telemetry events. The
    # handler is auto-detached on test exit so events don't leak between tests.
    # Mirrors the pattern used in Stacks.ObservabilityTelemetryTest.
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

    # Convention chosen for these tests (and to be enforced on the
    # implementer): the helper carries the failed git SHA in metadata under the
    # atom key :failed_sha (NOT "failed_sha" string, NOT :sha). This is
    # deliberate because Stacks.Audit.log/3's encode_uuid private helper
    # returns nil for non-UUID strings, so the SHA cannot live in the
    # resource_id column.

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

      # All five fields land in metadata
      assert entry.metadata[:failed_sha] == @valid_attrs.failed_sha
      assert entry.metadata[:target_image] == @valid_attrs.target_image
      assert entry.metadata[:modal_prev_commit] == @valid_attrs.modal_prev_commit
      assert entry.metadata[:reason] == @valid_attrs.reason
      assert entry.metadata[:triggered_by] == @valid_attrs.triggered_by
    end

    test "resource_id is nil because a git SHA is not a UUID; SHA lives in metadata" do
      assert {:ok, entry} = Audit.log_rollback(@valid_attrs)

      # encode_uuid returns nil for non-UUID strings (existing behaviour of
      # Stacks.Audit.log/3). The SHA must therefore be carried in metadata.
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

      # nil is preserved in metadata — the helper does not crash and does
      # not synthesise a placeholder string.
      assert Map.has_key?(entry.metadata, :modal_prev_commit)
      assert entry.metadata[:modal_prev_commit] == nil
    end

    test "emits [:stacks, :system, :rollback] telemetry once on success" do
      attach_telemetry([[:stacks, :system, :rollback]])

      assert {:ok, _entry} = Audit.log_rollback(@valid_attrs)

      assert_receive {:telemetry_event, [:stacks, :system, :rollback], measurements, metadata}

      assert measurements == %{count: 1}

      # Telemetry metadata mirrors the audit row metadata.
      assert metadata[:failed_sha] == @valid_attrs.failed_sha
      assert metadata[:target_image] == @valid_attrs.target_image
      assert metadata[:modal_prev_commit] == @valid_attrs.modal_prev_commit
      assert metadata[:reason] == @valid_attrs.reason
      assert metadata[:triggered_by] == @valid_attrs.triggered_by

      # Exactly once — no duplicate event.
      refute_receive {:telemetry_event, [:stacks, :system, :rollback], _, _}, 50
    end

    test "does NOT emit telemetry when the underlying audit insert fails" do
      attach_telemetry([[:stacks, :system, :rollback]])

      # Force the insert to fail by smuggling a non-JSON-encodable term
      # (a raw tuple) into the reason. Stacks.Audit.log/3 calls
      # Jason.encode!/1 on the metadata map, which raises
      # Protocol.UndefinedError for tuples; the rescue clause converts that
      # into {:error, _}. This path should NOT emit telemetry — otherwise
      # we'd have a misleading "we rolled back" signal for a rollback that
      # never recorded.
      bad_attrs = %{@valid_attrs | reason: {:not, :encodable}}

      assert {:error, _reason} = Audit.log_rollback(bad_attrs)

      refute_receive {:telemetry_event, [:stacks, :system, :rollback], _, _}, 50
    end
  end
end
