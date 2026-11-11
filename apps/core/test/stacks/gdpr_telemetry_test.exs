defmodule Stacks.GDPRTelemetryTest do
  @moduledoc """
      Firing tests for `[:stacks,:gdpr,...]` telemetry (121 Phase 4):
      export, deletion, and consent signals. Each test attaches a real
      handler, drives the flow, and asserts exact event name, measurement
      keys, and metadata — non-vacuous: removing an emitter times out the
      `assert_receive`.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Audit
  alias Stacks.GDPR.Consent
  alias Stacks.GDPR.ImageRetention
  alias Stacks.Workers.AccountDeletionJob
  alias Stacks.Workers.DataExportJob

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "test-gdpr-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "DataExportJob outcome telemetry" do
    test "emits [:stacks, :gdpr, :export] with result :ok + a non-negative duration on success" do
      attach_telemetry([[:stacks, :gdpr, :export]])
      user = insert(:user)

      assert :ok = perform_job(DataExportJob, %{"user_id" => user.id})

      assert_receive {:telemetry_event, [:stacks, :gdpr, :export], measurements, %{result: :ok}}

      assert %{count: 1, duration: duration} = measurements
      assert is_integer(duration) and duration >= 0
    end

    test "emits [:stacks, :gdpr, :export] with result :error + a duration on failure" do
      attach_telemetry([[:stacks, :gdpr, :export]])

      assert {:error, _} = perform_job(DataExportJob, %{"user_id" => Ecto.UUID.generate()})

      assert_receive {:telemetry_event, [:stacks, :gdpr, :export], measurements,
                      %{result: :error}}

      assert %{count: 1, duration: duration} = measurements
      assert is_integer(duration) and duration >= 0
    end
  end

  describe "AccountDeletionJob outcome telemetry" do
    test "emits [:stacks, :gdpr, :deletion] with result :ok + a non-negative duration on success" do
      attach_telemetry([[:stacks, :gdpr, :deletion]])
      user = insert(:user)

      assert :ok = perform_job(AccountDeletionJob, %{"user_id" => user.id})

      assert_receive {:telemetry_event, [:stacks, :gdpr, :deletion], measurements,
                      %{result: :ok, failed_step: :none}}

      assert %{count: 1, duration: duration} = measurements
      assert is_integer(duration) and duration >= 0
    end

    test "emits [:stacks, :gdpr, :deletion] with result :error, the failed-step id + a duration" do
      attach_telemetry([[:stacks, :gdpr, :deletion]])

      assert {:error, _} = perform_job(AccountDeletionJob, %{"user_id" => Ecto.UUID.generate()})

      assert_receive {:telemetry_event, [:stacks, :gdpr, :deletion], measurements,
                      %{result: :error, failed_step: :delete_user}}

      assert %{count: 1, duration: duration} = measurements
      assert is_integer(duration) and duration >= 0
    end
  end

  describe "consent telemetry" do
    test "emits [:stacks, :gdpr, :consent, :grant] on grant" do
      attach_telemetry([[:stacks, :gdpr, :consent, :grant]])
      user = insert(:user)

      assert {:ok, _} = Consent.grant_consent(user.id)

      assert_receive {:telemetry_event, [:stacks, :gdpr, :consent, :grant], %{count: 1},
                      %{feature: "analytics"}}
    end

    test "emits [:stacks, :gdpr, :consent, :revoke] on revoke" do
      attach_telemetry([[:stacks, :gdpr, :consent, :revoke]])
      user = insert(:user)

      assert {:ok, _} = Consent.revoke_consent(user.id)

      assert_receive {:telemetry_event, [:stacks, :gdpr, :consent, :revoke], %{count: 1},
                      %{feature: "analytics"}}
    end

    test "consent telemetry carries the bounded writing_assistant feature label" do
      attach_telemetry([
        [:stacks, :gdpr, :consent, :grant],
        [:stacks, :gdpr, :consent, :revoke]
      ])

      user = insert(:user)

      assert {:ok, _} = Consent.grant_consent(user.id, "writing_assistant")

      assert_receive {:telemetry_event, [:stacks, :gdpr, :consent, :grant], %{count: 1},
                      %{feature: "writing_assistant"}}

      assert {:ok, _} = Consent.revoke_consent(user.id, "writing_assistant")

      assert_receive {:telemetry_event, [:stacks, :gdpr, :consent, :revoke], %{count: 1},
                      %{feature: "writing_assistant"}}
    end
  end

  describe "image retention telemetry" do
    test "cleanup_expired_images/0 emits [:stacks, :gdpr, :image, :expired] with reason \"expired\"" do
      attach_telemetry([[:stacks, :gdpr, :image, :expired]])

      insert(:uploaded_image,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
        uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
      )

      assert {:ok, 1} = ImageRetention.cleanup_expired_images()

      assert_receive {:telemetry_event, [:stacks, :gdpr, :image, :expired], %{count: 1},
                      %{reason: "expired"}}
    end

    test "cleanup_stuck_images/0 emits both :stuck and :expired(by-reason \"stuck\")" do
      attach_telemetry([
        [:stacks, :gdpr, :image, :stuck],
        [:stacks, :gdpr, :image, :expired]
      ])

      insert(:uploaded_image,
        status: "pending",
        uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      )

      assert {:ok, 1} = ImageRetention.cleanup_stuck_images()

      assert_receive {:telemetry_event, [:stacks, :gdpr, :image, :stuck], %{count: 1},
                      %{reason: "stuck"}}

      assert_receive {:telemetry_event, [:stacks, :gdpr, :image, :expired], %{count: 1},
                      %{reason: "stuck"}}
    end

    test "missing_purge_check/0 emits [:stacks, :gdpr, :image, :orphan] with the orphan count" do
      attach_telemetry([[:stacks, :gdpr, :image, :orphan]])

      insert(:uploaded_image, expires_at: DateTime.add(DateTime.utc_now(), -1, :day))

      assert [_ | _] = ImageRetention.missing_purge_check()

      assert_receive {:telemetry_event, [:stacks, :gdpr, :image, :orphan], %{count: count}, %{}}
      assert count >= 1
    end
  end

  describe "audit write telemetry" do
    test "a KNOWN action reaches the metric labels unchanged" do
      # The pass-through half. Without it the bounding assertion below is
      # satisfied by a function that collapses everything to "other", which
      # would make the metric useless while looking correct.
      attach_telemetry([[:stacks, :gdpr, :audit, :write]])
      user = insert(:user)

      known_action = Audit.telemetry_actions() |> List.first()
      known_type = Audit.telemetry_resource_types() |> List.first()

      assert {:ok, _} = Audit.log(user.id, known_action, resource_type: known_type)

      assert_receive {:telemetry_event, [:stacks, :gdpr, :audit, :write], %{count: 1},
                      %{action: ^known_action, resource_type: ^known_type}}
    end

    test "an UNKNOWN action is bounded to \"other\" in the label and kept exactly in the row" do
      # Both halves of the contract, in one test because they are one decision.
      #
      # The audit ROW is the record and must be faithful, so it keeps whatever
      # string the caller passed. The LABEL is a Prometheus dimension — one
      # series per distinct value, forever, in a store with no erasure path — so
      # it is bounded to a known vocabulary with everything else collapsing to
      # "other".
      #
      # This test previously asserted the raw action reached the label, which was
      # true and was the defect: `Audit.log/3` accepts any string, so a caller
      # interpolating a resource name, an email or an id — the obvious thing to
      # do when debugging — minted a series per value.
      attach_telemetry([[:stacks, :gdpr, :audit, :write]])
      user = insert(:user)

      unknown_action = "test.telemetry_action"

      refute unknown_action in Audit.telemetry_actions(),
             "precondition: #{unknown_action} is now a known action, so this test no longer " <>
               "exercises the bounding path — pick one that is not in the vocabulary"

      assert {:ok, entry} = Audit.log(user.id, unknown_action, resource_type: "test")

      assert_receive {:telemetry_event, [:stacks, :gdpr, :audit, :write], %{count: 1},
                      %{action: "other", resource_type: "other"}}

      assert entry.action == unknown_action,
             "the audit ROW was bounded too. The row is the record of what happened and must " <>
               "keep the caller's exact string; only the metric label is a dimension."

      assert entry.resource_type == "test",
             "the audit row's resource_type was bounded too"
    end
  end

  describe "audit read telemetry" do
    test "Audit.list_for_user/2 emits [:stacks, :gdpr, :audit, :read] with no PII metadata" do
      attach_telemetry([[:stacks, :gdpr, :audit, :read]])
      user = insert(:user)

      assert {:ok, _} = Audit.log(user.id, "test.read_action", resource_type: "test")

      assert {[_ | _], total, 1, _per_page} = Audit.list_for_user(user.id)
      assert total >= 1

      assert_receive {:telemetry_event, [:stacks, :gdpr, :audit, :read], %{count: 1}, metadata}
      assert metadata == %{}
    end
  end
end
