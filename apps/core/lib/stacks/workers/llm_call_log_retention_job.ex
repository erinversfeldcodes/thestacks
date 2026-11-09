defmodule Stacks.Workers.LlmCallLogRetentionJob do
  @moduledoc """
      Drops LLM call records once they have outlived their purpose.

      ⛔ THE RETENTION IS THE SECOND HALF OF THE BOUND, AND WITHOUT IT THE FIRST
      HALF IS COSMETIC. `op.llm_call_log` caps each `raw_response` at 8 KB, which
      bounds what one bad response can write — it says nothing about a table that
      grows forever. A diagnostic record with no expiry quietly becomes a
      permanent archive of model output about readers' posts, which is a
      different thing from what was declared.

      ⚖️ 30 DAYS, BECAUSE OF WHAT THIS IS FOR. The record exists to answer "what
      did the model actually say" while someone is still asking — a debugging
      window and an eval-capture window. Neither is served by month-old rows, and
      the GDPR position is simpler the less of it there is.

      ⚠️ BATCHED, AND THE CEILING IS REPORTED. The sibling `AuditRetentionJob`
      records the opposite lesson: a single unbounded DELETE that sequentially
      scans a forever-growing table, survivable nightly and the wrong shape
      against a first backlog. This starts batched rather than learning that
      again — and `created_at` carries its own index, so the predicate can
      actually use one.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Stacks.AI.CallLog

  @retention_days 30
  @batch_size 1_000

  # ⚠️ A CEILING, not a target. A run that cannot finish must say so rather than
  # return :ok on a backlog — the shape that lets a retention failure stay
  # invisible behind a job that keeps succeeding.
  @max_batches 50

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days * 24 * 3600, :second)

    {deleted, batches} = delete_in_batches(cutoff, 0, 0)

    cond do
      deleted == 0 ->
        :ok

      batches >= @max_batches ->
        Logger.warning(
          "LlmCallLogRetentionJob: deleted #{deleted} row(s) and hit the #{@max_batches}-batch " <>
            "ceiling with records still older than #{@retention_days} days. The backlog is " <>
            "being worked down across runs, not cleared in this one."
        )

        :ok

      true ->
        Logger.info("LlmCallLogRetentionJob: deleted #{deleted} expired LLM call record(s)")
        :ok
    end
  end

  defp delete_in_batches(_cutoff, deleted, batches) when batches >= @max_batches,
    do: {deleted, batches}

  defp delete_in_batches(cutoff, deleted, batches) do
    # ⛔ Deletes by a selected id set rather than `WHERE created_at < $1`
    # directly, so the batch size is the thing that bounds the statement. A bare
    # predicate takes every matching row in one go, which is the sibling job's
    # recorded mistake.
    ids =
      CallLog
      |> where([c], c.created_at < ^cutoff)
      |> select([c], c.id)
      |> limit(^@batch_size)
      |> Repo.all()

    case ids do
      [] ->
        {deleted, batches}

      ids ->
        {count, _} = Repo.delete_all(from c in CallLog, where: c.id in ^ids)
        delete_in_batches(cutoff, deleted + count, batches + 1)
    end
  end

  @doc "How long a record is kept, in days — read by the test rather than restated."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days
end
