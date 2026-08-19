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
        * A statement-level trigger disarms it the moment one DELETE completes.
          So this is a single statement, not a batched loop — the second batch
          would be blocked by the trigger the first batch disarmed.

      That makes the delete unbounded in size on its first run against a long
      backlog. It is a nightly job on an indexed timestamp, and the alternative
      (batching) is not available to us, so the cost is accepted and named here
      rather than discovered later.
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

  @impl true
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_months * 30 * 24 * 3600, :second)

    result =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")

        %{num_rows: deleted} =
          Repo.query!(
            "DELETE FROM audit.audit_log WHERE occurred_at < $1",
            [cutoff]
          )

        deleted
      end)

    case result do
      {:ok, 0} ->
        :ok

      {:ok, deleted} ->
        Logger.info(
          "AuditRetentionJob: deleted #{deleted} audit row(s) older than #{@retention_months} months"
        )

        :ok

      {:error, reason} ->
        Logger.error("AuditRetentionJob: sweep failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
