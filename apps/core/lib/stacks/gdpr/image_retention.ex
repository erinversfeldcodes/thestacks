defmodule Stacks.GDPR.ImageRetention do
  @moduledoc """
      Handles cleanup of uploaded images.

      - `cleanup_finished_image_bytes/1` — deletes the PHOTOGRAPH once identification
        has been terminal for the reader's retry window, keeping the row
      - `cleanup_expired_images/1` — deletes images past their expires_at deadline (30 days)
      - `cleanup_stuck_images/1` — safety net for images that never finished:
        `pending` (the job wedged) and `awaiting_upload` (the bytes never came),
        both after #{@stuck_threshold_hours} hours
      - `cleanup_orphan_objects/1` — deletes objects no row points at

      ⚠️ The first of those is the only one that separates the two deadlines: a
      photograph is useless the moment identification finishes, while its record
      is still owed to the reader's inbox, their export and erasure. Everything
      else here deletes both halves together.

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

  # The prefix `Storage.upload_image/3` writes under (`"uploads/\#{image_id}"`).
  @upload_prefix "uploads/"

  # How many keys go into one `storage_path in (...)` query. Keeps a large
  # prefix off a single enormous parameter list without capping what is seen.
  @known_chunk 500

  # How long a photograph outlives the answer it produced.
  #
  # ⛔ THE BYTES AND THE RECORD HAVE DIFFERENT DEADLINES, and giving them one
  # deadline was the defect. `docs/technical-architecture.md` already states the
  # principle the code did not implement: a photo "exists solely to extract a
  # book identifier (ISBN)", and re-running vision on the original is
  # *deliberately* not preserved. So the photograph has no value once
  # identification is terminal — while the ROW keeps attribution, the reader's
  # inbox entry, the export and erasure reachability for its full 30 days.
  #
  # ⚠️ ONE THING still reads the bytes after a terminal status: "No, try again"
  # (`UploadController.reject_identification/2`), which re-enqueues
  # `IdentifyBookJob` against the same storage key. So this window is exactly
  # "how long does a reader get to reject a result", and nothing else. A day
  # covers a reader who closes the app and comes back the next evening.
  #
  # ⚖️ Why this matters more than tidiness: a shelf photograph routinely
  # captures other people — faces, rooms, a visible address — who consented to
  # nothing. The architecture offers the purge as the mitigation for that, and
  # a mitigation that waits 30 days after the image stopped being useful is a
  # weak one.
  @retry_window_hours 24

  # Terminal for the pipeline: the answer is in, right or wrong.
  @finished_statuses ["resolved", "rejected"]

  # ⛔ BOTH UNFINISHED STATUSES, and the second one is the point.
  #
  # `cleanup_stuck_images/1` filtered `status == "pending"` only — so
  # `awaiting_upload`, the ONE status that means the bytes never arrived, was
  # the one status the stuck-image sweep could not see. `init_upload/2` inserts
  # the row and hands back an upload URL; if the client never PUTs, nothing
  # collected the row until its 30-day expiry, where it was then counted as an
  # "expired image" — which is not what happened to it.
  #
  # ⚖️ Measured on production while characterising the row-less objects: of 15
  # sampled rows whose `storage_path` pointed at an object that does not exist,
  # three were `awaiting_upload` reservations from months earlier. Their objects
  # were never created at all.
  #
  # ⚠️ `reject_image/2` already scopes to exactly these two, so the two statuses
  # were handled together everywhere EXCEPT here. That is part of why nobody
  # noticed.
  @unfinished_statuses ["pending", "awaiting_upload"]

  # ⚠️ The clock for both is `uploaded_at`, which is set at RESERVATION time by
  # `init_upload/2` — NOT when bytes arrived, despite the name. For an
  # unredeemed reservation that is exactly the right clock: the question is how
  # long ago the key was reserved. For a wedged `pending` row it is slightly
  # conservative, since the row became `pending` at commit, some time after the
  # reservation — so the sweep fires marginally sooner than "two hours stuck".
  # Named because the column's name invites the opposite assumption, and the
  # single-write guard rejected it for that same reason.
  defp reason_for_status("awaiting_upload"), do: "unredeemed"
  defp reason_for_status(_pending), do: "stuck"

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
      Deletes the stored photograph for images whose identification finished
      more than #{@retry_window_hours} hours ago, and clears the `storage_path`
      that pointed at it. **The row survives** to its own `expires_at`.

      Returns `{:ok, count}` — rows whose object is now gone. Bounded like its
      siblings; `drain/1` loops it.

      ⚠️ `updated_at` is the terminal timestamp and needs no column of its own,
      because nothing moves a finished row except `reject_identification/2` —
      which moves it back to `pending` and so restarts this clock, correctly:
      the reader is working with that image again. `mark_resolved/2` writes only
      `where status == "pending"` and `reject_image/2` only
      `where status in ("awaiting_upload", "pending")`, so neither can re-fire
      on a row that is already finished.
  """
  @spec cleanup_finished_image_bytes(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_finished_image_bytes(opts \\ []) do
    limit = Keyword.get(opts, :limit, @batch_size)
    cutoff = DateTime.add(DateTime.utc_now(), -@retry_window_hours, :hour)

    rows =
      UploadedImage
      |> where([i], i.status in ^@finished_statuses)
      |> where([i], not is_nil(i.storage_path) and i.storage_path != "")
      |> where([i], i.updated_at < ^cutoff)
      |> order_by([i], asc: i.updated_at)
      |> limit(^limit)
      |> select([i], %{id: i.id, storage_path: i.storage_path})
      |> Repo.all()

    # ⛔ THE OBJECT GOES FIRST, AND ONLY WHAT ACTUALLY WENT HAS ITS PATH CLEARED.
    #
    # ⚖️ Both orderings can fail, and they fail toward different states. Clearing
    # the path first and then failing to delete leaves an object no row points
    # at — unreachable by erasure, unattributable, exactly the population the
    # row-less sweep below exists to mop up, manufactured deliberately. Deleting
    # first and then failing to clear leaves a row pointing at a gone object:
    # visible, attributable, and retried by the next run of this sweep. Fail
    # toward the reachable state.
    #
    # So a storage failure is NOT swallowed here, where `delete_storage_objects/1`
    # swallows it for the sweeps that delete the row anyway. The row is staying,
    # so its path must keep pointing at whatever is actually there.
    {deleted, failed} = delete_storage_objects(rows)

    if failed != [] do
      Logger.warning(
        "ImageRetention: #{length(failed)} finished image object(s) could not be deleted; " <>
          "their rows keep their storage_path and the next run retries them"
      )
    end

    deleted_ids = Enum.map(deleted, & &1.id)

    {count, _} =
      UploadedImage
      |> where([i], i.id in ^deleted_ids)
      |> Repo.update_all(set: [storage_path: nil])

    emit_discard_events(deleted_ids)

    :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: count}, %{
      reason: "finished"
    })

    {:ok, count}
  rescue
    error -> {:error, error}
  end

  @doc """
      Deletes upload objects that no `op.uploaded_images` row points at.

      ⛔ WHY A ROW-LESS OBJECT IS A GDPR PROBLEM AND NOT MERE UNTIDINESS. Both
      mechanisms that are supposed to reach image bytes work FROM the rows:
      `cleanup_expired_images/1` selects rows and deletes their `storage_path`,
      and `GDPR.Deletion`'s `:delete_image_objects` step collects `id` +
      `storage_path` for a user's rows *before* `repo.delete(user)`, precisely
      because the rows are the only pointer to the bytes. An object with no row
      is outside both: not erasable, not expirable, and not attributable to any
      user — so it can be neither reached by a subject-access request nor
      deleted on one.

      ⚠️ They already exist independently of any defect: a crash between
      `store_upload_bytes/3` and `commit_upload/2` leaves bytes with a row that
      a later sweep removes, and until this function there was nothing that
      could collect the remainder.

      ⚖️ Safe to delete unconditionally because the ordering is one-way: a row
      is reserved by `init_upload/2` BEFORE any bytes can be written, and
      `store_upload_bytes/3` refuses an id with no row. So an object without a
      row is one whose row has gone, never one whose row is still coming.

      ⛔ WHY THE BOUND IS ON THE DELETES AND NOT ON THE KEYS EXAMINED. The
      obvious bound — take the first `limit` keys and diff those — makes the
      sweep **blind**, and that is not a performance opinion. Object keys are
      UUIDs, so a listing's order is arbitrary but STABLE: the same first
      `limit` keys come back every run. If they all have rows, the sweep
      reports `{:ok, 0}` forever while an orphan sits further down the listing,
      never examined. A sweep that cannot see most of its own prefix is worse
      than no sweep, because it reports success.

      So the whole listing is examined, the `in` query is chunked to
      `@known_chunk` keys per round trip, and `limit` caps the DELETES — the
      expensive and irreversible half. `drain/1` then works a real backlog down
      across runs, as it does for the two sweeps above.

      ⚠️ `Storage.list_objects/1` still answers with the whole prefix in one
      list, which grows with total uploads stored rather than with work to do.
      Bounding that needs a paged `list/2` on the storage behaviour and its
      three other callers; it is a cost, not a correctness problem, and it is
      not fixed here.
  """
  @spec cleanup_orphan_objects(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  # BOUNDED SWEEP: the `in` query is chunked to `@known_chunk` keys per call and
  # the DELETES are capped at `limit`. ⚠️ The bound is deliberately NOT on the
  # keys examined — see the @doc; capping those makes the sweep blind.
  def cleanup_orphan_objects(opts \\ []) do
    limit = Keyword.get(opts, :limit, @batch_size)

    case Stacks.Storage.list_objects(@upload_prefix) do
      {:ok, keys} ->
        orphans =
          keys
          |> Enum.chunk_every(@known_chunk)
          |> Enum.flat_map(&reject_known(&1))
          |> Enum.take(limit)

        Enum.each(orphans, &Stacks.Storage.delete_object/1)

        # ⛔ `reason: "rowless"`, NOT `"orphaned"`, and the word matters here.
        # `[:stacks, :gdpr, :image, :orphan]` already exists and means the
        # OPPOSITE defect — "images past expiry still in the DB", a row the
        # sweep failed to collect — and it is alarm-wired: the GDPR dashboard
        # says ANY non-zero orphan is alert-worthy. This counts an OBJECT with
        # no row, which is a routine collection rather than an alarm. Two
        # different facts sharing a name on the same dashboard is how an
        # operator mis-reads an incident.
        :telemetry.execute(
          [:stacks, :gdpr, :image, :expired],
          %{count: length(orphans)},
          %{reason: "rowless"}
        )

        {:ok, length(orphans)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp reject_known(keys) do
    known =
      UploadedImage
      |> where([i], i.storage_path in ^keys)
      |> select([i], i.storage_path)
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(keys, &MapSet.member?(known, &1))
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
      |> where([i], i.status in ^@unfinished_statuses and i.uploaded_at < ^threshold)
      |> order_by([i], asc: i.uploaded_at)
      |> limit(^limit)
      |> select([i], %{id: i.id, storage_path: i.storage_path, status: i.status})
      |> Repo.all()

    stuck_ids = Enum.map(stuck_rows, & &1.id)

    delete_storage_objects(stuck_rows)

    {count, _} =
      UploadedImage
      |> where([i], i.id in ^stuck_ids)
      |> Repo.delete_all()

    # ⛔ COUNTED APART, because they are different facts about the system. A
    # `pending` row is work that STARTED and wedged — the identification job
    # failed silently or never ran. An `awaiting_upload` row is a reservation
    # nobody redeemed: the bytes never arrived, so there is no job, nothing
    # failed, and a reader simply walked away. Reporting both as "stuck" would
    # make a rise in abandoned uploads look like a rise in broken ones, which
    # are opposite problems with opposite fixes.
    by_reason = Enum.frequencies_by(stuck_rows, &reason_for_status(&1.status))

    emit_expiry_events(stuck_ids, %{reason: "stuck"})

    for {reason, n} <- by_reason do
      :telemetry.execute([:stacks, :gdpr, :image, :stuck], %{count: n}, %{reason: reason})
      :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: n}, %{reason: reason})
    end

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
      The STANDING populations on both sides of the `uploads/` prefix, as a
      gauge rather than a collection counter.

      Returns `%{objects:, rows_with_path:, rowless_objects:, rows_without_object:}`.

      ⛔ **A COLLECTION COUNTER AND A STANDING POPULATION ARE DIFFERENT NUMBERS,
      and only one of them can alarm.** `cleanup_orphan_objects/1` already emits
      how many row-less objects it DELETED. A sweep that never runs emits zero —
      the same zero as a sweep that ran and found nothing. That is the wrong
      zero, and it is exactly how this population reached 4,234 objects on
      production while every counter on the dashboard read fine.

      ⚖️ **It reports BOTH directions, and the second one is the point.** The
      issue this closes asked only for "objects must not exceed rows". Measured
      on production 2026-11-05, that invariant would have been **blind to the
      larger defect**: 4,234 objects had no row, and 2,374 rows pointed at an
      object that no longer existed. An arithmetic check on the two totals sees
      the difference, 1,860 — which is neither number, and which shrinks toward
      zero as the two populations grow in step. So both are counted and both
      alarm.

      ⚠️ A NULL `storage_path` is NOT a row without an object. Since
      `cleanup_finished_image_bytes/1`, a finished row legitimately has no path
      and no object, and counting those here would alarm on the normal case.
      Only rows that still claim a path are measured.

      ⚠️ Like `cleanup_orphan_objects/1`, this reads the whole prefix listing
      into memory — see the note there. It is a nightly check, not a request
      path.
  """
  @spec storage_consistency_check() :: {:ok, map()} | {:error, term()}
  def storage_consistency_check do
    case Stacks.Storage.list_objects(@upload_prefix) do
      {:ok, keys} ->
        # One pass over the keys gives both answers: whatever matched is the
        # overlap, and each side's total minus the overlap is its own orphans.
        # Counted DISTINCT so a path duplicated across rows cannot inflate the
        # overlap and hide an orphan on either side.
        matched =
          keys
          |> Enum.chunk_every(@known_chunk)
          |> Enum.map(&count_known/1)
          |> Enum.sum()

        rows_with_path =
          UploadedImage
          |> where([i], not is_nil(i.storage_path) and i.storage_path != "")
          |> Repo.aggregate(:count)

        result = %{
          objects: length(keys),
          rows_with_path: rows_with_path,
          rowless_objects: length(keys) - matched,
          rows_without_object: rows_with_path - matched
        }

        emit_standing(result)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  # ⛔ Its own event, NOT `[:stacks, :gdpr, :image, :orphan]` and NOT `:expired`
  # with a reason. `:orphan` means a ROW past expiry still in the DB and is
  # already alarm-wired; `:expired` counts bytes REMOVED. This is neither — it
  # is how many are standing right now, which is the only one of the three that
  # can be read as "is the system currently correct?".
  defp emit_standing(%{rowless_objects: rowless, rows_without_object: missing}) do
    :telemetry.execute([:stacks, :gdpr, :image, :standing], %{count: rowless}, %{
      population: "rowless_objects"
    })

    :telemetry.execute([:stacks, :gdpr, :image, :standing], %{count: missing}, %{
      population: "rows_without_object"
    })
  end

  defp count_known(keys) do
    UploadedImage
    |> where([i], i.storage_path in ^keys)
    |> select([i], count(i.storage_path, :distinct))
    |> Repo.one()
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
      `storage_path`, and **reports which ones actually went**. Returns
      `{deleted, failed}`, both lists of the rows given.

      ⚖️ A storage failure does NOT block the DB-side removal, and that policy
      is deliberate: a surviving row still pointing a reader at their image is
      an erasure leak, while a leaked object is not reachable by anyone.

      ⛔ But "the caller may ignore a failure" and "the caller cannot SEE a
      failure" are different things, and this used to be the second. It returned
      a bare `:ok`, so `GDPR.Deletion` reported `length(rows)` as its deletion
      count — during a storage outage, erasure would report five objects deleted
      having deleted none, then remove the rows, leaving objects that no row
      points at. That population is not hypothetical: a production
      characterisation found 4,234 of them, and the reason it was expensive is
      precisely that nothing records WHICH objects leaked at the moment they do.

      So the failure is now returned. What the caller does with it is the
      caller's decision; what it may no longer do is report success for it.

      Shared by the retention sweeps AND by `Stacks.GDPR.Deletion.delete_user_data/1`,
      which calls it while erasing a user so the objects go BEFORE the FK cascade
      removes the rows (the rows are the only pointer to the storage keys). Takes a
      list of `%{storage_path: String.t | nil}` maps.

      ⚠️ A row with no usable `storage_path` counts as DELETED: there is nothing
      to remove, and reporting it as a failure would make a caller retry forever.
      Since `cleanup_finished_image_bytes/1`, a finished row legitimately has a
      `nil` path, so this is the common case rather than an edge.
  """
  @spec delete_storage_objects([%{optional(any) => any}]) :: {[map()], [map()]}
  def delete_storage_objects(rows) do
    Enum.split_with(rows, fn
      %{storage_path: path} when is_binary(path) and path != "" ->
        case Storage.delete_image(path) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning(
              "ImageRetention: failed to delete storage object #{path}: #{inspect(reason)}"
            )

            false
        end

      _ ->
        true
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
  # ⛔ A DISTINCT EVENT TYPE, not `image.expired` with another reason, and the
  # distinction is the one event_log exists to make. `image.expired` means the
  # image is gone — row and bytes — which is what an erasure enquiry reads it
  # as. This one says the photograph was discarded while its record remains. The
  # telemetry series is still shared, because "how many bytes did we remove
  # tonight" is genuinely one question; "what happened to this image" is not.
  defp emit_discard_events([]), do: :ok

  defp emit_discard_events(image_ids) do
    events =
      Enum.map(image_ids, fn image_id ->
        %{
          event_type: "image.bytes_discarded",
          aggregate_type: "image",
          aggregate_id: image_id,
          payload: %{reason: "finished"}
        }
      end)

    case Events.emit_many(events) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ImageRetention: #{length(image_ids)} image.bytes_discarded event(s) were not " <>
            "recorded: #{inspect(reason)}"
        )

        :ok
    end
  end

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
