defmodule Stacks.DataCorrection.UnrunnableImageJob do
  @moduledoc """
      Discards queued image-identification jobs whose image no longer exists.

      A job keyed on `args->>'image_id'` cannot succeed once that
      `op.uploaded_images` row is gone: there is nothing to identify, so every
      attempt fails, retries, and lands in `discarded` anyway. This gets it there
      without spending the attempts — and, on the vision path, without spending
      GPU time on each one.

      ## Why this exists at all

      The core machine scales to zero, and until `Oban.Plugins.Lifeline` was added
      nothing returned a job interrupted by a suspend to `available`. Production
      accumulated 91 `oban_jobs` rows in state `executing` and no other state, 76
      of them image-identification jobs stale between 97 and 180 days. The images
      they name were purged long ago: 70 distinct, well-formed image ids, zero
      matching a live row.

      ⚠️ **Lifeline alone would make that worse before it made it better.** It
      transitions a stuck job back to `available` (or to `discarded` only once
      attempts are exhausted), so switching it on without this correction
      resurrects all 70 — each then failing to find its image, retrying to its
      attempt ceiling, and only then being discarded. That is roughly 140
      executions down the vision path for no possible result.

      ## Why a correction rather than one-off SQL

      The incident that produced this was a step that existed, worked, and was
      wired into one pipeline but not another. Fixing it with a manual step an
      operator has to remember to run at the right moment would repeat exactly
      that mistake. A registered correction rides both deploy paths
      automatically, writes an audit row in the same transaction as the change,
      and is a single cheap SELECT reporting nothing to do once the rows are
      gone.

      It also keeps earning its place on a branched or restored database, which
      is the registry's stated reason corrections stay registered: the production
      lineage carries these rows, so a rollback branch or a restored backup
      carries them too.
  """

  @behaviour Stacks.DataCorrection

  alias Core.Repo

  # ⚠️ THE STALENESS FLOOR IS THE SAFETY PROPERTY, not a tidiness filter.
  #
  # "Its image is missing" is not on its own a safe predicate over a live job
  # table: the retention sweep deletes images, so a job could be genuinely
  # mid-flight on an image purged a moment ago, and discarding that is
  # destroying running work. Every other correction in the registry targets seed
  # fixtures by exact id, which carries no such risk; this one matches on a
  # condition, so it needs a reason the match cannot catch live work.
  #
  # An hour is that reason. It is four times `Lifeline`'s 15-minute
  # `rescue_after`, so anything still sitting here has already had its chance to
  # be rescued, and it is far beyond any legitimate enqueue-to-run latency on
  # this app's queues. Measured against the rows this was written for, the
  # margin is not close: the youngest was stale by 9 days.
  @stale_after_seconds 3600

  # `inserted_at`, not `attempted_at`, because a rescued job sitting in
  # `available` has never been attempted and `attempted_at` is NULL there — so
  # keying on it would skip precisely the rows Lifeline has already moved.
  @states ~w(executing available retryable)

  @impl true
  def name, do: "unrunnable_image_job"

  @impl true
  def resource_type, do: "oban_job"

  @impl true
  def scope do
    "queued image-identification jobs older than an hour whose uploaded image no longer exists"
  end

  @impl true
  def reversibility do
    {:one_way,
     "the job's input image is gone, so it can never succeed in any state; the audit row keeps " <>
       "its id, worker and image id if the history is ever needed"}
  end

  @impl true
  def plan do
    case Repo.query(candidates_sql(), [@stale_after_seconds, @states]) do
      {:ok, %{rows: rows}} ->
        for [id, worker, image_id, state, inserted_at] <- rows do
          %{
            id: to_string(id),
            from: "#{state} (image #{image_id} absent)",
            to: "discarded",
            because:
              "#{worker} enqueued #{inserted_at} names an uploaded image that no longer exists",
            detail: %{worker: worker, image_id: image_id, previous_state: state}
          }
        end

      # A database without the table is not a failure to report — it is a
      # correction with nothing in scope, which is the same answer as a clean one.
      {:error, _} ->
        []
    end
  end

  @impl true
  def apply_change(%{id: id}) do
    # ⚠️ The UPDATE re-states the WHOLE predicate rather than trusting the id
    # from `plan/0`. Between planning and applying, Lifeline may have moved the
    # row, a retry may have started, or the image may have reappeared — and in
    # every one of those cases this should do nothing rather than force the
    # transition. Matching on the condition, not just the id, is what makes a
    # drifted row refused instead of overwritten.
    case Repo.query(discard_sql(), [id, @stale_after_seconds, @states]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, {:row_no_longer_matches, id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidates_sql do
    """
    SELECT j.id, j.worker, j.args->>'image_id', j.state::text, j.inserted_at
      FROM public.oban_jobs j
     WHERE #{predicate()}
     ORDER BY j.inserted_at
    """
  end

  defp discard_sql do
    """
    UPDATE public.oban_jobs j
       SET state = 'discarded', discarded_at = now()
     -- `$1::text::bigint`, not `$1::bigint`: every other correction in the
     -- registry keys on a UUID, so the framework's change shape carries `id` as
     -- a string, while `oban_jobs.id` is a bigint. Casting through text lets
     -- Postgrex encode the parameter it was actually given instead of rejecting
     -- it. ⚠️ `--apply` is the only thing that exercises this — a dry run never
     -- calls `apply_change/1`, so it reported a clean plan over a write that
     -- could not execute.
     WHERE j.id = $1::text::bigint
       AND #{predicate(offset: 1)}
    """
  end

  # One predicate, used by both statements, so the plan and the guarded write
  # cannot drift apart — the failure mode where a correction reports one
  # population and writes to another.
  defp predicate(opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    stale = "$#{offset + 1}::integer"
    states = "$#{offset + 2}::text[]"

    """
    to_regclass('public.oban_jobs') IS NOT NULL
      AND j.state::text = ANY(#{states})
      AND j.inserted_at < now() - make_interval(secs => #{stale})
      AND j.args->>'image_id' IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM op.uploaded_images i
         WHERE i.id::text = j.args->>'image_id'
      )
    """
  end
end
