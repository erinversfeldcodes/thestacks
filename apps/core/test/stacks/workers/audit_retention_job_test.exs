defmodule Stacks.Workers.AuditRetentionJobTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  alias Core.Repo
  alias Stacks.Workers.AuditRetentionJob

  # Insert directly: Stacks.Audit.log/3 stamps occurred_at with NOW(), and this
  # job is entirely about rows whose age we control.
  defp seed_audit_row(action, occurred_at) do
    Repo.query!(
      """
      INSERT INTO audit.audit_log (id, user_id, action, resource_type, occurred_at, success)
      VALUES (gen_random_uuid(), gen_random_uuid(), $1, 'probe', $2, true)
      """,
      [action, occurred_at]
    )
  end

  defp count(action) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM audit.audit_log WHERE action = $1", [action])

    n
  end

  describe "perform/1" do
    test "deletes rows past the retention period and keeps rows inside it" do
      now = DateTime.utc_now()
      months = AuditRetentionJob.retention_months()

      # Comfortably outside the window.
      seed_audit_row("probe.ancient", DateTime.add(now, -(months + 2) * 30 * 24 * 3600, :second))
      # Comfortably inside it — this is the assertion that stops the job being a
      # table-truncation dressed as retention.
      seed_audit_row("probe.recent", DateTime.add(now, -30 * 24 * 3600, :second))

      assert count("probe.ancient") == 1
      assert count("probe.recent") == 1

      assert :ok = perform_job(AuditRetentionJob, %{})

      assert count("probe.ancient") == 0, "a row past the retention period should be gone"
      assert count("probe.recent") == 1, "a row inside the retention period must survive"
    end

    test "clears a backlog larger than one batch, across batches" do
      # ⛔ The sweep was one unbounded DELETE, and its own moduledoc recorded that
      # both justifications for that were false: batching IS permitted (the
      # append-only trigger authorises per STATEMENT, not per transaction), and
      # the timestamp was NOT indexed, so the DELETE Seq Scanned a table designed
      # to grow forever. Both are fixed; this is what holds the batching.
      #
      # ⚠️ The property is that MORE THAN ONE batch runs and the backlog still
      # clears. A single-batch test would pass against the unbounded version, and
      # a test that only counted the total would pass against a loop that stopped
      # after one pass and left rows behind.
      now = DateTime.utc_now()
      months = AuditRetentionJob.retention_months()
      old_at = DateTime.add(now, -(months + 2) * 30 * 24 * 3600, :second)

      # ⚠️ The batch size is LOWERED, and without that this test is worthless.
      #
      # The production size is 5,000. Any backlog small enough to seed quickly
      # fits in one batch, so the test would exercise a single statement and pass
      # against the unbounded DELETE it is meant to guard. An earlier version of
      # this test did exactly that while its comment claimed otherwise.
      #
      # Two rows per batch over five rows forces three iterations, the last
      # short — which is also the condition the loop uses to decide it has
      # finished.
      Application.put_env(:core, :audit_retention_batch_size, 2)
      on_exit(fn -> Application.delete_env(:core, :audit_retention_batch_size) end)

      for _ <- 1..5, do: seed_audit_row("probe.backlog", old_at)
      assert count("probe.backlog") == 5
      assert AuditRetentionJob.batch_size() == 2, "the batch size override did not take"

      assert :ok = perform_job(AuditRetentionJob, %{})

      assert count("probe.backlog") == 0,
             "five rows did not clear at two per batch, so the loop ran once and stopped. A " <>
               "sweep that reports :ok having left rows past their retention period is the " <>
               "failure this batching exists to avoid."
    end

    test "the error path can actually run, which the branch it replaced could not" do
      # ⛔ `perform/1` used to end in `{:error, reason} -> ...` matching
      # `Repo.transaction/1`, which returns that ONLY for an explicit
      # `Repo.rollback/1`. Nothing rolls back here and `Repo.query!` RAISES, so
      # the failure path was a raise propagating straight past a case clause
      # written to catch it. The clause read as error handling and handled
      # nothing — which is worse than no clause, because a reader stops looking.
      #
      # Driven by revoking the authorisation the append-only trigger demands: the
      # DELETE then raises, and the rescue must turn that into an error tuple
      # Oban can retry rather than an unhandled exit.
      now = DateTime.utc_now()
      months = AuditRetentionJob.retention_months()
      seed_audit_row("probe.raises", DateTime.add(now, -(months + 2) * 30 * 24 * 3600, :second))

      # `audit.audit_log` refuses an unauthorised DELETE by raising inside the
      # trigger. Pointing the job at a relation that does not exist reaches the
      # same place with no dependence on trigger internals.
      Repo.query!("ALTER TABLE audit.audit_log RENAME TO audit_log_renamed_for_probe")

      on_exit(fn ->
        Repo.query!("ALTER TABLE audit.audit_log_renamed_for_probe RENAME TO audit_log")
      end)

      assert {:error, message} = perform_job(AuditRetentionJob, %{})

      assert is_binary(message),
             "the rescue must report a message Oban can log and retry on, not an unhandled raise"
    end

    test "keeps the retention period at the ruled twenty-four months" do
      # Deliberately a constant assertion, and the only one here that is.
      #
      # Every other test derives its dates from `retention_months/0`, so the job
      # and its tests move together — which is what makes them robust to the
      # period changing, and also what makes them completely blind to it. Cutting
      # the constant from 24 to 3 leaves all of them green while silently
      # shortening how long the audit trail survives.
      #
      # The period is a decision, not an implementation detail. Pinning it means
      # changing it requires changing this line, which puts the change in front of
      # a reviewer instead of letting it pass as a tuning tweak.
      assert AuditRetentionJob.retention_months() == 24
    end

    test "succeeds when there is nothing to delete" do
      assert :ok = perform_job(AuditRetentionJob, %{})
    end

    test "deletes through the append-only trigger, which refuses an unauthorised DELETE" do
      # Guard-of-guard: prove the trigger the job works around is really armed,
      # so the job's GUC handling is load-bearing rather than ceremonial.
      seed_audit_row("probe.trigger", DateTime.add(DateTime.utc_now(), -3600, :second))

      assert_raise Postgrex.Error, fn ->
        Repo.query!("DELETE FROM audit.audit_log WHERE action = 'probe.trigger'")
      end

      assert count("probe.trigger") == 1
    end
  end
end
