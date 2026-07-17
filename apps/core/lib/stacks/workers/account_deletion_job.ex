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
        # `failed_step: :none` keeps the tag set identical to the failure branch.
        # The PromEx counter declares `tags: [:result, :failed_step]`; a metadata
        # map missing a declared tag key fails reporter validation and the series
        # is silently dropped — so the success path must carry `:failed_step` too.
        :telemetry.execute([:stacks, :gdpr, :deletion], %{count: 1}, %{
          result: :ok,
          failed_step: :none
        })

        :ok

      {:error, step, reason, _changes} ->
        Logger.error(
          "AccountDeletionJob: deletion failed at #{step} for user #{user_id}: #{inspect(reason)}"
        )

        # GDPR telemetry: carry the failed Ecto.Multi step id so operators can
        # see *where* an erasure broke, not just that it did. Registered in
        # `Core.PromEx.Plugins.Stacks` as `stacks_gdpr_deletion_count_total`,
        # tagged by `:result` and `:failed_step`.
        :telemetry.execute([:stacks, :gdpr, :deletion], %{count: 1}, %{
          result: :error,
          failed_step: step
        })

        {:error, "deletion failed at #{step}"}
    end
  end
end
