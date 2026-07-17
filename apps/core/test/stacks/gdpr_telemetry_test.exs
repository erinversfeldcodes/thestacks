defmodule Stacks.GDPRTelemetryTest do
  @moduledoc """
  Firing tests for GDPR-specific telemetry (Issue #121, Phase 4;
  technical-architecture "Observability & Metrics" — GDPR signals).

  Each test attaches a real `:telemetry` handler, exercises the GDPR flow,
  and asserts the exact `[:stacks, :gdpr, ...]` event name, measurement keys,
  and metadata. These assertions are non-vacuous: removing any emitter makes
  the corresponding `assert_receive` time out and the test fail.

  Covered signals:
    * `[:stacks, :gdpr, :export]`            — DataExportJob outcome
    * `[:stacks, :gdpr, :deletion]`          — AccountDeletionJob outcome + failed-step id
    * `[:stacks, :gdpr, :consent, :grant]`   — consent grant count
    * `[:stacks, :gdpr, :consent, :revoke]`  — consent revoke count
    * `[:stacks, :gdpr, :image, :expired]`   — expired count + expired-by-reason
    * `[:stacks, :gdpr, :image, :stuck]`     — stuck count
    * `[:stacks, :gdpr, :image, :orphan]`    — orphan count
    * `[:stacks, :gdpr, :audit, :write]`     — audit-log write throughput
  """

  # async: false — telemetry handlers are process-global state.
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

  # ── Export / Deletion job outcomes ─────────────────────────────────────────

  describe "DataExportJob outcome telemetry" do
    test "emits [:stacks, :gdpr, :export] with result :ok + a non-negative duration on success" do
      attach_telemetry([[:stacks, :gdpr, :export]])
      user = insert(:user)

      assert :ok = perform_job(DataExportJob, %{"user_id" => user.id})

      # Issue #238: the emit now carries the job wall-time in the `:duration`
      # measurement (ms) so the latency distribution can watch the 30-day SLA.
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

      # `failed_step: :none` on success keeps the tag set identical to the
      # failure branch so the PromEx counter records both series (see plugin).
      # Issue #238: the emit also carries the job wall-time in `:duration` (ms).
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

  # ── Consent grant / revoke ─────────────────────────────────────────────────

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

  # ── Image retention: expired / stuck / orphan + by-reason ──────────────────

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

  # ── Audit-log write throughput ─────────────────────────────────────────────

  describe "audit write telemetry" do
    test "Audit.log/3 emits [:stacks, :gdpr, :audit, :write] on a successful insert" do
      attach_telemetry([[:stacks, :gdpr, :audit, :write]])
      user = insert(:user)

      assert {:ok, _} = Audit.log(user.id, "test.telemetry_action", resource_type: "test")

      assert_receive {:telemetry_event, [:stacks, :gdpr, :audit, :write], %{count: 1},
                      %{action: "test.telemetry_action", resource_type: "test"}}
    end
  end

  # ── Audit-log read throughput (Issue #238) ─────────────────────────────────

  describe "audit read telemetry" do
    test "Audit.list_for_user/2 emits [:stacks, :gdpr, :audit, :read] with no PII metadata" do
      attach_telemetry([[:stacks, :gdpr, :audit, :read]])
      user = insert(:user)

      # A prior write so the listing has a row (the read emit fires regardless).
      assert {:ok, _} = Audit.log(user.id, "test.read_action", resource_type: "test")

      assert {[_ | _], total, 1, _per_page} = Audit.list_for_user(user.id)
      assert total >= 1

      # Untagged, empty-metadata emit: no user-id/handle/IP reaches the sink.
      assert_receive {:telemetry_event, [:stacks, :gdpr, :audit, :read], %{count: 1}, metadata}
      assert metadata == %{}
    end
  end
end
