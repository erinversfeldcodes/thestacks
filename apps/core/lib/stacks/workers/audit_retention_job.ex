defmodule Stacks.Workers.AuditRetentionJob do
  @moduledoc """
      Nightly sweep that deletes `audit.audit_log` rows older than the retention
      period.

      The audit trail is deliberately retained past a user's erasure, on a
      different lawful basis to the rest of their data. "Retained past erasure"
      and "retained forever" are different claims, though, and only the first was
      ever decided — until this job existed, nothing pruned the table and rows
      accumulated indefinitely. Storage limitation is its own obligation,
      independent of the right to erasure.

      ⛔ Two constraints shape the implementation, both from the table's
      append-only triggers:

        * DELETE is refused unless `app.audit_gdpr_erasure` is set, so the sweep
          has to arm it inside its own transaction.
        * A statement-level trigger disarms it the moment one DELETE completes,
          so the grant covers exactly ONE statement. It can be re-armed: a second
          `SET LOCAL app.audit_gdpr_erasure = 'true'` authorises the next
          statement in the same transaction.

      ⚠️ Two earlier claims here were wrong. They are corrected rather than
      quietly deleted, because both were load-bearing — the accepted cost below
      rested on them:

        * "the alternative (batching) is not available to us" — **false.**
          Probed: two authorised DELETEs in one transaction, re-arming between
          them, both succeed and both rows go. The grant is per-statement, not
          per-transaction.
        * "a nightly job on an indexed timestamp" — **false.** The only index
          touching `occurred_at` is `(user_id, occurred_at)`, which cannot drive
          `WHERE occurred_at < $1` when there is no `user_id` predicate. `EXPLAIN`
          against the real table returns a **Seq Scan**.

      So this is a single unbounded DELETE by choice rather than by constraint,
      and it sequentially scans a table that grows forever. Survivable nightly at
      today's volume; the wrong shape for a first run against a long backlog. The
      fix is an `occurred_at` index plus a batched loop that re-arms per batch.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Core.Repo

  # Ruled 2026-08-19. The capacity model already assumes this table is
  # partitioned by year, so two years is the shortest period that keeps a full
  # prior year available for comparison.
  @retention_months 24

  @doc "The retention period, in months. One place, so the job and its tests agree."
  @spec retention_months() :: pos_integer()
  def retention_months, do: @retention_months

  # ⚠️ A BOUND per statement, because the alternative was one unbounded DELETE
  # over a table designed to grow forever.
  #
  # The moduledoc above records that both reasons given for the unbounded form
  # were false: batching IS available (the erasure grant is per-statement, not
  # per-transaction, probed with two authorised DELETEs in one transaction), and
  # the timestamp was NOT indexed. The index now exists, so the sweep can select
  # its rows; this is the other half.
  #
  # 5,000 keeps each statement's lock window short on a table written from the
  # request path, while still clearing a year of ordinary volume in a handful of
  # iterations.
  @batch_size 5_000

  @doc """
      Rows deleted per statement. Configurable so a test can drive the LOOP
      rather than the constant.

      ⚠️ Not a convenience. With the production size, any test small enough to
      be fast runs exactly one batch — and a one-batch test passes against the
      unbounded DELETE this replaced, which makes it worthless as a guard on the
      batching. The first version of that test claimed to exercise the loop and
      did not.
  """
  @spec batch_size() :: pos_integer()
  def batch_size, do: Application.get_env(:core, :audit_retention_batch_size, @batch_size)

  # Enough iterations to drain a long backlog, bounded so a job run always ends.
  # Reaching this is not an error — the next scheduled run continues, and the
  # log says so rather than implying the sweep finished.
  @max_batches 50

  @impl true
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_months * 30 * 24 * 3600, :second)

    # ⛔ ONE TRANSACTION PER BATCH, and the GUC re-armed inside each one.
    #
    # `SET LOCAL` is scoped to its transaction, so a single outer transaction
    # would make the loop one long lock-holder — which is the shape this change
    # exists to end. Re-arming per batch is what the probe in the moduledoc
    # established is permitted: the append-only trigger authorises per
    # statement, not per transaction.
    {deleted, batches} = delete_in_batches(cutoff, 0, 0)

    cond do
      deleted == 0 ->
        :ok

      batches >= @max_batches ->
        # ⚠️ Said explicitly. The run succeeded and the sweep did NOT finish —
        # conflating those is how a retention backlog stays invisible behind a
        # job that keeps reporting :ok.
        Logger.warning(
          "AuditRetentionJob: deleted #{deleted} audit row(s) and hit the #{@max_batches}-batch " <>
            "ceiling with rows still older than #{@retention_months} months. The backlog is " <>
            "being worked down across runs, not cleared in this one."
        )

        :ok

      true ->
        Logger.info(
          "AuditRetentionJob: deleted #{deleted} audit row(s) older than #{@retention_months} months"
        )

        :ok
    end
  rescue
    # ⚠️ A `rescue`, because the branch this replaces could never run.
    #
    # It matched `{:error, reason}` from `Repo.transaction/1`, which only returns
    # that for an explicit `Repo.rollback/1`. Nothing here rolls back, and
    # `Repo.query!` RAISES — so the failure path was a raise propagating past a
    # case clause written to catch it. The clause read as error handling and
    # handled nothing.
    error ->
      Logger.error("AuditRetentionJob: sweep failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  defp delete_in_batches(_cutoff, deleted, batches) when batches >= @max_batches,
    do: {deleted, batches}

  defp delete_in_batches(cutoff, deleted, batches) do
    {:ok, count} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")

        %{num_rows: count} =
          Repo.query!(
            """
            DELETE FROM audit.audit_log
             WHERE id IN (
               SELECT id FROM audit.audit_log
                WHERE occurred_at < $1
                ORDER BY occurred_at
                LIMIT $2
             )
            """,
            [cutoff, batch_size()]
          )

        count
      end)

    # Fewer than a full batch means the predicate is now empty. A count equal to
    # the batch size says nothing about what remains, so only this proves it is
    # finished.
    if count < batch_size() do
      {deleted + count, batches + 1}
    else
      delete_in_batches(cutoff, deleted + count, batches + 1)
    end
  end
end
