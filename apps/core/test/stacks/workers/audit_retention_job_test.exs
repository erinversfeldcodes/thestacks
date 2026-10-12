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
