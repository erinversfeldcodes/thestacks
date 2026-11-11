defmodule Stacks.DataCorrection.UnrunnableImageJobTest do
  @moduledoc """
      The scope cut is the whole correction. This one does not key on an exact
      id like its siblings — it matches a CONDITION over a live job table, so
      what it refuses to touch matters more than what it discards.

      Three negative controls carry that weight: a job too young to be an
      orphan, a job whose image still exists, and a job already in a terminal
      state. Each is deliberately close to the target and must survive.
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.DataCorrection
  alias Stacks.DataCorrection.UnrunnableImageJob

  @absent_image "11111111-1111-1111-1111-111111111111"

  defp insert_job(opts) do
    state = Keyword.fetch!(opts, :state)
    image_id = Keyword.fetch!(opts, :image_id)
    age_seconds = Keyword.fetch!(opts, :age_seconds)
    inserted_at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO public.oban_jobs
          (state, queue, worker, args, inserted_at, scheduled_at, attempt, max_attempts)
        VALUES ($1::oban_job_state, 'vision', 'Stacks.Workers.IdentifyBookJob',
                jsonb_build_object('image_id', $2::text), $3, $3, 1, 3)
        RETURNING id
        """,
        [state, image_id, inserted_at]
      )

    id
  end

  defp state_of(id) do
    %{rows: [[state]]} =
      Repo.query!("SELECT state::text FROM public.oban_jobs WHERE id = $1", [id])

    state
  end

  defp apply_it do
    DataCorrection.run_all([UnrunnableImageJob], apply: true, invoked_by: "test")
  end

  describe "what it discards" do
    test "an executing job whose image is gone — the shape production accumulated" do
      id = insert_job(state: "executing", image_id: @absent_image, age_seconds: 100 * 86_400)

      assert {:ok, _} = apply_it()
      assert state_of(id) == "discarded"
    end

    test "a job already rescued to available, because that is the Lifeline race" do
      # ⚠️ This is why `available` is in scope and not just `executing`. The
      # rescue plugin and this correction both run on a deployed stack, and
      # whichever moves first, the job still cannot succeed — its image is gone.
      # Covering only `executing` would leave the rescued ones to fail one
      # attempt at a time, which is the exact waste this exists to prevent.
      id = insert_job(state: "available", image_id: @absent_image, age_seconds: 50 * 86_400)

      assert {:ok, _} = apply_it()
      assert state_of(id) == "discarded"
    end
  end

  describe "what it must not touch" do
    test "a job too young to be an orphan, even with its image gone" do
      # ⛔ The staleness floor is the safety property. The retention sweep
      # deletes images, so a job can be genuinely mid-flight on an image purged
      # moments ago — and discarding that destroys running work. An hour is four
      # times the rescue window, so anything older has already had its chance.
      id = insert_job(state: "executing", image_id: @absent_image, age_seconds: 300)

      assert {:ok, _} = apply_it()

      assert state_of(id) == "executing",
             "a five-minute-old job was discarded — the staleness floor is gone, and with it " <>
               "the only thing separating an orphan from live work"
    end

    test "a stale job whose image still exists" do
      image = insert(:uploaded_image)
      id = insert_job(state: "executing", image_id: image.id, age_seconds: 90 * 86_400)

      assert {:ok, _} = apply_it()

      assert state_of(id) == "executing",
             "a job that can still succeed was discarded — the correction is matching on age " <>
               "alone rather than on the image being absent"
    end

    test "a job already in a terminal state" do
      id = insert_job(state: "completed", image_id: @absent_image, age_seconds: 80 * 86_400)

      assert {:ok, _} = apply_it()
      assert state_of(id) == "completed"
    end
  end

  describe "the framework contract" do
    test "it is a no-op on a clean table, and says so" do
      assert UnrunnableImageJob.plan() == []
    end

    test "re-running after applying finds nothing" do
      insert_job(state: "executing", image_id: @absent_image, age_seconds: 100 * 86_400)

      assert {:ok, _} = apply_it()
      assert UnrunnableImageJob.plan() == []
    end

    test "applying writes an audit row per change, in the same transaction" do
      insert_job(state: "executing", image_id: @absent_image, age_seconds: 100 * 86_400)

      before =
        Repo.query!("SELECT count(*) FROM audit.audit_log WHERE resource_type = 'oban_job'")

      assert {:ok, _} = apply_it()

      after_ =
        Repo.query!("SELECT count(*) FROM audit.audit_log WHERE resource_type = 'oban_job'")

      [[before_count]] = before.rows
      [[after_count]] = after_.rows

      assert after_count == before_count + 1,
             "no audit row was written. The framework's contract is no audit, no change — a " <>
               "correction that mutates a job table unrecorded is worse than one that does nothing"
    end

    test "a row that stops matching between plan and apply is refused, not forced" do
      # ⚠️ `apply_change/1` re-states the whole predicate rather than trusting
      # the planned id, so a row the rescue plugin or a retry moved underneath us
      # is left alone. Simulated by planning first, then moving the row.
      id = insert_job(state: "executing", image_id: @absent_image, age_seconds: 100 * 86_400)

      [change] = UnrunnableImageJob.plan()
      assert change.id == to_string(id)

      Repo.query!("UPDATE public.oban_jobs SET state = 'completed' WHERE id = $1", [id])

      assert {:error, {:row_no_longer_matches, _}} = UnrunnableImageJob.apply_change(change)
      assert state_of(id) == "completed"
    end
  end
end
