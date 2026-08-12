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
        emit_outcome(%{result: :ok, failed_step: :none}, started_at)

        :ok

      {:error, step, reason, _changes} ->
        Logger.error(
          "AccountDeletionJob: deletion failed at #{step} for user #{user_id}: #{inspect(reason)}"
        )

        emit_outcome(%{result: :error, failed_step: step}, started_at)

        {:error, "deletion failed at #{step}"}
    end
  end

  defp emit_outcome(metadata, started_at) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    :telemetry.execute([:stacks, :gdpr, :deletion], %{count: 1, duration: duration_ms}, metadata)
  end
end
