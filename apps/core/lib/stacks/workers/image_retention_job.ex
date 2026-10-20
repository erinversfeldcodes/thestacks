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

    # ⚠️ DRAINED IN BATCHES UNDER A DEADLINE, not swept in one pass.
    #
    # This used to call each sweep once, and each sweep took every matching row.
    # On production that was 6,655 expired rows in a single run — 6,655 storage
    # deletions and as many event inserts — on a machine that suspends when
    # idle. The run never finished, nothing rescued the interrupted job, and the
    # backlog grew until the oldest unpurged row was 151 days past expiry.
    #
    # Splitting the budget between the two sweeps keeps a large expired backlog
    # from starving the stuck-image safety net, which is the one that stops
    # `pending` rows accumulating in the first place.
    with {:ok, stuck_count, stuck_state} <-
           ImageRetention.drain(&ImageRetention.cleanup_stuck_images/1, budget_ms: 30_000),
         {:ok, expired_count, expired_state} <-
           ImageRetention.drain(&ImageRetention.cleanup_expired_images/1, budget_ms: 30_000) do
      Logger.info(
        "ImageRetentionJob: cleaned up #{stuck_count} stuck (#{stuck_state}) + " <>
          "#{expired_count} expired (#{expired_state}) image records"
      )

      # ⚠️ Said out loud, because the alternative is a log line that reads like
      # success. Hitting the deadline means rows REMAIN past their expiry when
      # this job reports `:ok` — the job completing is not the sweep being done,
      # and conflating the two is what let the backlog hide.
      for {label, state} <- [{"stuck", stuck_state}, {"expired", expired_state}],
          state == :deadline do
        Logger.warning(
          "ImageRetentionJob: #{label} sweep hit its time budget with work remaining — " <>
            "the backlog is being worked down across runs, not cleared in this one"
        )
      end

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

  @doc """
      How many uploaded images remain past their expiry. Zero when the sweep is
      caught up.

      ⚠️ This is the number that matters most in this group, because
      `perform/1` drains under a 30-second budget per sweep and returns `:ok`
      when it hits that deadline with work remaining. The job completing and
      the backlog being clear are different facts; production once held 6,655
      expired rows behind a job reporting success every night, with the oldest
      151 days past expiry.

      Delegates to `ImageRetention.missing_purge_check/0` — the same check the
      job itself alarms on — rather than restating what "past expiry" means.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: length(ImageRetention.missing_purge_check())
end
