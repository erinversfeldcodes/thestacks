defmodule Stacks.Workers.ImageRetentionJob do
  @moduledoc """
      Nightly retention worker for uploaded images.

      ⛔ THE SENTENCE THAT USED TO STAND HERE — "images are normally deleted
      immediately by IdentifyBookJob on success" — WAS NOT TRUE, and had not
      been for as long as the module existed. Nothing deleted an image on
      success; every photograph sat in object storage for the full 30-day row
      TTL, long after the only thing that ever read it was finished. The
      architecture document described the same behaviour this docstring claimed
      ("the image has no further operational or user value" once identification
      succeeds), so both artefacts described a deletion neither of them
      performed.

      `ImageRetention.cleanup_finished_image_bytes/1` is that deletion, and it
      runs FIRST below: every other sweep here is a safety net for a photograph
      that never reached a terminal state, so the common case should not depend
      on one.
  """

  use Stacks.Worker, scope: :system, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.GDPR.ImageRetention

  @impl true
  def perform(_job) do
    Logger.info("ImageRetentionJob: discarding finished photographs and sweeping records")

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
    with {:ok, finished_count, finished_state} <-
           ImageRetention.drain(&ImageRetention.cleanup_finished_image_bytes/1,
             budget_ms: 30_000
           ),
         {:ok, stuck_count, stuck_state} <-
           ImageRetention.drain(&ImageRetention.cleanup_stuck_images/1, budget_ms: 30_000),
         {:ok, expired_count, expired_state} <-
           ImageRetention.drain(&ImageRetention.cleanup_expired_images/1, budget_ms: 30_000),
         # ⛔ The orphan sweep runs LAST and from this job, because a sweep
         # nothing invokes is a sweep that does not run — this repository has
         # recorded a runner proven working and left uncalled. It goes last
         # because the two above DELETE rows, which is how objects become
         # orphaned in the first place; sweeping before them would leave this
         # run's own leavings for the next one.
         {:ok, orphan_count, orphan_state} <-
           ImageRetention.drain(&ImageRetention.cleanup_orphan_objects/1, budget_ms: 30_000) do
      Logger.info(
        "ImageRetentionJob: discarded #{finished_count} finished photograph(s) " <>
          "(#{finished_state}), cleaned up #{stuck_count} stuck (#{stuck_state}) + " <>
          "#{expired_count} expired (#{expired_state}) image records, and " <>
          "#{orphan_count} row-less object(s) (#{orphan_state})"
      )

      # ⚠️ Said out loud, because the alternative is a log line that reads like
      # success. Hitting the deadline means rows REMAIN past their expiry when
      # this job reports `:ok` — the job completing is not the sweep being done,
      # and conflating the two is what let the backlog hide.
      for {label, state} <- [
            {"finished", finished_state},
            {"stuck", stuck_state},
            {"expired", expired_state},
            {"orphan", orphan_state}
          ],
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

      alarm_on_standing_populations()

      :ok
    else
      {:error, reason} ->
        Logger.error("ImageRetentionJob: cleanup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ⛔ READ AFTER THE SWEEPS, so it measures what this run LEFT rather than what
  # it found. A standing population is the only one of the three image numbers
  # that answers "is the system correct right now" — the sweep counters report
  # zero both when they found nothing and when they never ran.
  #
  # ⚠️ A storage failure is logged and swallowed. This is a measurement; it must
  # not fail a job whose deletions already succeeded, and an unreadable bucket
  # is itself visible as the gauge going stale.
  defp alarm_on_standing_populations do
    case ImageRetention.storage_consistency_check() do
      {:ok, %{rowless_objects: rowless, rows_without_object: missing} = counts} ->
        if rowless > 0 do
          Logger.error(
            "ImageRetentionJob: ALARM — #{rowless} object(s) under uploads/ that no row points at. " <>
              "They are unreachable by erasure and attributable to nobody."
          )
        end

        if missing > 0 do
          Logger.error(
            "ImageRetentionJob: ALARM — #{missing} row(s) whose storage_path resolves to nothing. " <>
              "Any read of them fails; the arithmetic check alone cannot see this direction."
          )
        end

        Logger.info("ImageRetentionJob: storage consistency #{inspect(counts)}")

      {:error, reason} ->
        Logger.warning(
          "ImageRetentionJob: could not measure storage consistency: #{inspect(reason)}"
        )
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
