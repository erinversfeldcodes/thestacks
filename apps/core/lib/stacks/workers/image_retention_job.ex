defmodule Stacks.Workers.ImageRetentionJob do
  @moduledoc """
  Nightly safety net Oban worker. Cleans up uploaded images that are stuck in
  `pending` status (i.e. their IdentifyBookJob failed or never ran).

  Images are normally deleted immediately by IdentifyBookJob on success.
  This job handles edge cases where that didn't happen.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.GDPR.ImageRetention

  @impl true
  def perform(_job) do
    Logger.info("ImageRetentionJob: cleaning up stuck and expired images")

    with {:ok, stuck_count} <- ImageRetention.cleanup_stuck_images(),
         {:ok, expired_count} <- ImageRetention.cleanup_expired_images() do
      Logger.info(
        "ImageRetentionJob: cleaned up #{stuck_count} stuck + #{expired_count} expired image records"
      )

      orphaned = ImageRetention.missing_purge_check()

      if orphaned != [] do
        Logger.error(
          "ImageRetentionJob: ALARM — #{length(orphaned)} orphaned image(s) past expiry: #{inspect(orphaned)}"
        )
      end

      :ok
    else
      {:error, reason} ->
        Logger.error("ImageRetentionJob: cleanup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
