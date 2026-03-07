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

    case Deletion.delete_user_data(user_id) do
      {:ok, _} ->
        Logger.info("AccountDeletionJob: successfully deleted data for user #{user_id}")
        :ok

      {:error, step, reason, _changes} ->
        Logger.error(
          "AccountDeletionJob: deletion failed at #{step} for user #{user_id}: #{inspect(reason)}"
        )

        {:error, "deletion failed at #{step}"}
    end
  end
end
