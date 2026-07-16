defmodule Stacks.Workers.AccountDeletionJob do
  @moduledoc """
  Oban worker that executes the GDPR right-to-erasure deletion for a user account.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Stacks.GDPR.Deletion

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Logger.info("AccountDeletionJob: deleting data for user #{user_id}")
    started_at = System.monotonic_time()

    case Deletion.delete_user_data(user_id) do
      {:ok, _} ->
        Logger.info("AccountDeletionJob: successfully deleted data for user #{user_id}")
        # `failed_step: :none` keeps the tag set identical to the failure branch.
        # The PromEx counter declares `tags: [:result, :failed_step]`; a metadata
        # map missing a declared tag key fails reporter validation and the series
        # is silently dropped — so the success path must carry `:failed_step` too.
        emit_outcome(%{result: :ok, failed_step: :none}, started_at)

        :ok

      {:error, step, reason, _changes} ->
        Logger.error(
          "AccountDeletionJob: deletion failed at #{step} for user #{user_id}: #{inspect(reason)}"
        )

        # GDPR telemetry: carry the failed Ecto.Multi step id so operators can
        # see *where* an erasure broke, not just that it did.
        emit_outcome(%{result: :error, failed_step: step}, started_at)

        {:error, "deletion failed at #{step}"}
    end
  end

  # GDPR telemetry: one event per deletion job carrying the outcome (+ failed
  # step) AND the job wall-time. Registered in `Core.PromEx.Plugins.Stacks` as
  # `stacks_gdpr_deletion_count_total` (counter, tagged `:result`/`:failed_step`)
  # and `stacks_gdpr_deletion_duration_milliseconds` (distribution, Issue #238)
  # so p95 can watch the 30-day erasure SLA. `:duration` is milliseconds.
  defp emit_outcome(metadata, started_at) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    :telemetry.execute([:stacks, :gdpr, :deletion], %{count: 1, duration: duration_ms}, metadata)
  end
end
