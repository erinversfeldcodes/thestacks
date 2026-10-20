defmodule Stacks.GDPR.ImageRetention do
  @moduledoc """
      Handles cleanup of uploaded images.

      - `cleanup_expired_images/0` — deletes images past their expires_at deadline (30 days)
      - `cleanup_stuck_images/0` — safety net: cleans up images stuck in pending
        for longer than 2 hours (e.g. if IdentifyBookJob never ran or failed silently)

      Both functions delete the object from storage (R2/Local/Mock) when a
      `storage_path` is present, then remove the DB record and emit an
      `image.expired` event for each deleted record.
  """

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.UploadedImage
  alias Stacks.Events
  alias Stacks.Storage

  @stuck_threshold_hours 2

  # ⚠️ BOTH SWEEPS ARE BOUNDED, and the bound is not a tuning knob — it is what
  # makes them able to finish at all.
  #
  # They used to select every matching row with a bare `Repo.all()`. Measured on
  # production: 6,655 expired rows, so one run meant 6,655 storage deletions, a
  # `delete_all` whose `id in ^ids` list was 6,655 long, and 6,655 immutable
  # event_log inserts — on a machine `min_machines_running = 0` suspends when
  # idle.
  #
  # ⛔ That turned a missed sweep into a RATCHET. The run could not finish before
  # the machine went away; nothing rescued the interrupted job, so it sat in
  # `executing` forever; the next run faced the same backlog plus a day. The
  # longer it had been broken the less able it was to recover, and the oldest
  # unpurged row was 151 days past its expiry when this was found. A retention
  # promise cannot be kept by an operation whose cost grows with how long it has
  # been failing.
  #
  # A batch of 200 is small enough that a run completes well inside any plausible
  # suspend window, and the caller drains in batches, so progress is monotonic
  # and every individual job run reaches a clean `:ok`.
  @batch_size 200

  @doc """
      Deletes up to `:limit` uploaded_images records where `expires_at < now`,
      oldest expiry first.
      Removes the corresponding object from storage, then the DB record.
      Emits `image.expired` for each deleted record.
      Returns `{:ok, count}` with the number of deleted records.

      ⚠️ ONE BATCH, not the whole backlog — see `@batch_size`. A caller that
      needs the backlog cleared uses `drain/1`, which loops this under a
      deadline. `count < limit` means the backlog is now empty.
  """
  @spec cleanup_expired_images(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired_images(opts \\ []) do
    now = DateTime.utc_now()
    limit = Keyword.get(opts, :limit, @batch_size)

    expired_rows =
      UploadedImage
      |> where([i], not is_nil(i.expires_at) and i.expires_at < ^now)
      |> order_by([i], asc: i.expires_at)
      |> limit(^limit)
      |> select([i], %{id: i.id, storage_path: i.storage_path})
      |> Repo.all()

    expired_ids = Enum.map(expired_rows, & &1.id)

    delete_storage_objects(expired_rows)

    {count, _} =
      UploadedImage
      |> where([i], i.id in ^expired_ids)
      |> Repo.delete_all()

    emit_expiry_events(expired_ids, %{})

    :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: count}, %{reason: "expired"})

    {:ok, count}
  rescue
    error -> {:error, error}
  end

  @doc """
      Deletes uploaded_images records stuck in `pending` status for longer than
      #{@stuck_threshold_hours} hours. These are images whose IdentifyBookJob
      failed silently or never ran.
      Removes the corresponding object from storage, then the DB record.
      Emits `image.expired` for each deleted record.
      Returns `{:ok, count}`.
  """
  @spec cleanup_stuck_images(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_stuck_images(opts \\ []) do
    threshold = DateTime.add(DateTime.utc_now(), -@stuck_threshold_hours * 3600, :second)
    limit = Keyword.get(opts, :limit, @batch_size)

    stuck_rows =
      UploadedImage
      |> where([i], i.status == "pending" and i.uploaded_at < ^threshold)
      |> order_by([i], asc: i.uploaded_at)
      |> limit(^limit)
      |> select([i], %{id: i.id, storage_path: i.storage_path})
      |> Repo.all()

    stuck_ids = Enum.map(stuck_rows, & &1.id)

    delete_storage_objects(stuck_rows)

    {count, _} =
      UploadedImage
      |> where([i], i.id in ^stuck_ids)
      |> Repo.delete_all()

    emit_expiry_events(stuck_ids, %{reason: "stuck"})

    :telemetry.execute([:stacks, :gdpr, :image, :stuck], %{count: count}, %{reason: "stuck"})
    :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: count}, %{reason: "stuck"})

    {:ok, count}
  rescue
    error -> {:error, error}
  end

  @doc """
      Runs `fun` in `@batch_size` batches until the backlog is empty or the
      deadline passes, and returns `{:ok, total_deleted, :drained | :deadline}`.

      ⚠️ A DEADLINE, not just a batch count, and the distinction is the whole
      design. The machine this runs on scales to zero and suspends when idle, so
      the only safe shape for a sweep is "make progress for at most N seconds,
      then return cleanly". A run that tries to finish an arbitrarily large
      backlog is a run that gets interrupted, and an interrupted Oban job with no
      rescue plugin stays `executing` forever — which is how a backlog reaches
      151 days without a single completed sweep.

      So this never tries to be the last word. It guarantees forward progress and
      a clean exit; the next scheduled run continues. `:deadline` in the return
      is the signal that a backlog remains, and the caller logs it rather than
      pretending the sweep was exhaustive.
  """
  @spec drain((keyword() -> {:ok, non_neg_integer()} | {:error, term()}), keyword()) ::
          {:ok, non_neg_integer(), :drained | :deadline} | {:error, term()}
  def drain(fun, opts \\ []) do
    limit = Keyword.get(opts, :limit, @batch_size)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, 60_000)

    drain_loop(fun, limit, deadline, 0)
  end

  defp drain_loop(fun, limit, deadline, total) do
    case fun.(limit: limit) do
      # Fewer than a full batch came back, so the query that selects the backlog
      # is now empty. This is the only condition that proves exhaustion — a
      # count equal to the limit says nothing about what remains.
      {:ok, count} when count < limit ->
        {:ok, total + count, :drained}

      {:ok, count} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:ok, total + count, :deadline}
        else
          drain_loop(fun, limit, deadline, total + count)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
      Returns image IDs that should have been purged but weren't.

      Finds images with `image.submitted`, `image.resolved`, or `image.rejected`
      events whose `expires_at` has passed, but which have no corresponding
      `image.expired` event. These are orphaned images that the retention job
      missed.

      Run daily as a health check — a non-empty result indicates a retention gap.
  """
  @spec missing_purge_check() :: [String.t()]
  def missing_purge_check do
    cutoff = DateTime.utc_now()

    query =
      from(i in UploadedImage,
        where: i.expires_at < ^cutoff,
        select: %{id: i.id, storage_path: i.storage_path}
      )

    orphaned = Repo.all(query)
    count = length(orphaned)

    if orphaned != [] do
      Logger.warning(
        "ImageRetention: missing-purge alarm — #{count} image(s) past expiry still in DB"
      )
    end

    :telemetry.execute([:stacks, :gdpr, :image, :orphan], %{count: count}, %{})

    Enum.map(orphaned, & &1.id)
  end

  @doc """
      Deletes the storage object for each row that carries a non-empty
      `storage_path`. A storage-layer failure is logged and swallowed — it must
      never block the DB-side removal (a leaked object is recoverable; a surviving
      DB row that still points a user at their image is the erasure leak).

      Shared by the retention sweeps AND by `Stacks.GDPR.Deletion.delete_user_data/1`,
      which calls it while erasing a user so the R2 objects go BEFORE the FK cascade
      removes the rows (the rows are the only pointer to the storage keys). Takes a
      list of `%{storage_path: String.t | nil}` maps.
  """
  @spec delete_storage_objects([%{optional(any) => any}]) :: :ok
  def delete_storage_objects(rows) do
    Enum.each(rows, fn
      %{storage_path: path} when is_binary(path) and path != "" ->
        case Storage.delete_image(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ImageRetention: failed to delete storage object #{path}: #{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end)
  end

  # ⛔ ONE statement for the whole batch, not one per image — and this is the
  # difference between a backlog that clears and one that does not.
  #
  # These sweeps used to call `Events.emit_safe/1` per deleted row, and
  # `emit/1` costs TWO round-trips each (the event_log insert plus the
  # subscriber enqueue). Measured on a deployed stack: 200 deletions meant 400
  # sequential round-trips to a networked Postgres and consumed the sweep's
  # entire 30-second budget, so one run cleared exactly one batch however large
  # the backlog was. Production's 6,655 expired rows were 34 nightly runs away
  # from being gone.
  #
  # ⚠️ Still best-effort, exactly as `emit_safe/1` was: the images are already
  # deleted by the time this runs, so a failed event must not fail the sweep and
  # undo nothing. What changes is that the failure is now LOGGED WITH ITS SIZE
  # rather than once per row — a batch that silently emitted nothing would leave
  # the deletions unrecorded in an immutable log that is supposed to be the
  # record of them.
  defp emit_expiry_events([], _payload), do: :ok

  defp emit_expiry_events(image_ids, payload) do
    events =
      Enum.map(image_ids, fn image_id ->
        %{
          event_type: "image.expired",
          aggregate_type: "image",
          aggregate_id: image_id,
          payload: payload
        }
      end)

    case Events.emit_many(events) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ImageRetention: #{length(image_ids)} image.expired event(s) were not recorded: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  end
end
