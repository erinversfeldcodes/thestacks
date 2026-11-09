defmodule Stacks.Workers.LlmCallLogRetentionJobTest do
  @moduledoc """
      That the retention actually retires rows, and only the right ones.

      ⛔ A RETENTION JOB IS THE EASIEST THING TO WRITE AND NEVER NOTICE IS DEAD.
      It deletes nothing visible, returns `:ok` either way, and the table it
      sweeps is one nobody reads — so a sweep that selects zero rows forever is
      indistinguishable from one that works. Every case here drives a real row
      past the boundary and looks.
  """
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.AI.CallLog
  alias Stacks.Workers.LlmCallLogRetentionJob

  defp a_call_aged(days) do
    user = insert(:user)
    post = insert(:post, user: user)

    {:ok, entry} =
      %CallLog{}
      |> CallLog.changeset(%{
        post_id: post.id,
        model: "m",
        prompt_sha256: CallLog.hash_prompt("p"),
        outcome: "associated",
        raw_response: "[]"
      })
      |> Repo.insert()

    # ⚠️ Backdated with an UPDATE rather than by inserting a crafted timestamp:
    # `created_at` carries a database default, so passing one through the
    # changeset is ignored and every row would be "now" — a fixture that
    # silently disagrees with its own name.
    at = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)
    Repo.update_all(from(c in CallLog, where: c.id == ^entry.id), set: [created_at: at])

    entry
  end

  defp ids, do: Repo.all(from c in CallLog, select: c.id)

  describe "what it sweeps" do
    test "a record past the retention window is deleted" do
      old = a_call_aged(LlmCallLogRetentionJob.retention_days() + 1)

      # ⛔ ANTI-VACUITY: the row must be there first, or this asserts nothing.
      assert old.id in ids()

      assert :ok = perform_job(LlmCallLogRetentionJob, %{})

      refute old.id in ids(),
             "a record older than the retention window survived the sweep — the 8 KB " <>
               "bound limits what one response writes, this is what limits how long it stays"
    end

    # ⚖️ Not redundant with the case above: a sweep that deleted EVERYTHING
    # would pass it. This is the half that says the boundary is a boundary.
    test "a record inside the window is kept" do
      recent = a_call_aged(1)

      assert :ok = perform_job(LlmCallLogRetentionJob, %{})

      assert recent.id in ids(),
             "a day-old record was swept — the window is 30 days, and a sweep that takes " <>
               "everything is not retention, it is deletion"
    end

    test "both at once, so the cut lands between them" do
      old = a_call_aged(45)
      recent = a_call_aged(2)

      assert :ok = perform_job(LlmCallLogRetentionJob, %{})

      remaining = ids()
      refute old.id in remaining
      assert recent.id in remaining
    end

    # ⚠️ An empty sweep is a legitimate outcome and must not be an error — the
    # job runs nightly against a table that is usually already clean.
    test "nothing to do is still a success" do
      assert :ok = perform_job(LlmCallLogRetentionJob, %{})
    end
  end

  describe "it works in batches, which is its stated shape" do
    # ⛔ A PROBE REPLACED THE WHOLE BATCH LOOP WITH ONE UNBOUNDED DELETE AND
    # LEFT 5 TESTS GREEN. The moduledoc argues at length that batching exists so
    # as not to repeat `AuditRetentionJob`'s recorded mistake — a single
    # unbounded DELETE sequentially scanning a forever-growing table, survivable
    # nightly and the wrong shape against a first backlog. Nothing would have
    # noticed its removal.
    #
    # ⚖️ Asserted on the BEHAVIOUR a batch size produces — more rows than one
    # batch holds, all gone, across several statements — rather than on the
    # function's existence, which a rewrite would satisfy while losing the
    # property.
    test "more rows than one batch still all go" do
      user = insert(:user)
      post = insert(:post, user: user)

      ids =
        for _ <- 1..5 do
          {:ok, entry} =
            %CallLog{}
            |> CallLog.changeset(%{
              post_id: post.id,
              model: "m",
              prompt_sha256: CallLog.hash_prompt("p"),
              outcome: "associated"
            })
            |> Repo.insert()

          entry.id
        end

      at = DateTime.add(DateTime.utc_now(), -90 * 24 * 3600, :second)
      Repo.update_all(from(c in CallLog, where: c.id in ^ids), set: [created_at: at])

      # ⛔ A SMALL BATCH SIZE, so the shape is observable. With the production
      # 1_000 this test would pass against a single unbounded DELETE — the rows
      # go either way, and only the statement count differs.
      Application.put_env(:core, :llm_call_log_batch_size, 2)
      on_exit(fn -> Application.delete_env(:core, :llm_call_log_batch_size) end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:stacks, :ai, :call_log_retention_batch]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      assert :ok = perform_job(LlmCallLogRetentionJob, %{})

      remaining = ids()

      assert Enum.all?(ids, &(&1 not in remaining)),
             "a backlog larger than one batch must be cleared across batches, not " <>
               "partially swept and reported :ok"

      assert_received {[:stacks, :ai, :call_log_retention_batch], ^ref, %{deleted: 2}, _}

      assert_received {[:stacks, :ai, :call_log_retention_batch], ^ref, %{deleted: 2}, _},
                      "five rows at a batch size of two must take several bounded " <>
                        "statements — one unbounded DELETE is the shape this job exists " <>
                        "not to have"
    end

    # ⚠️ THE CEILING BRANCH, which a probe setting `@max_batches 1` left green
    # while the job logged "records still older than 30 days" about a table with
    # none left. A branch that reports a backlog it never checked for is worse
    # than one that says nothing.
    test "the batch size and ceiling are real numbers, not decoration" do
      assert LlmCallLogRetentionJob.batch_size() > 1,
             "a batch size of one makes every run hit the ceiling and report a backlog " <>
               "that does not exist"

      assert LlmCallLogRetentionJob.max_batches() *
               LlmCallLogRetentionJob.batch_size() > 1_000,
             "the ceiling must be able to clear a realistic night's rows in one run, or " <>
               "every run reports an unfinished backlog"
    end
  end

  describe "it is reachable" do
    # ⛔ THE ASSERTION THAT USED TO BE HERE PASSED WHILE ITS OWN MESSAGE WAS
    # TRUE. It checked `function_exported?(Stacks.Release, :sweep_llm_call_log,
    # 0)` and failed with "the sweep has no scheduled caller, so the retention
    # policy only runs when someone remembers to run it" — and at the moment it
    # was written, nothing scheduled it. The function existed; the schedule did
    # not. A test whose failure text describes the live defect while reporting
    # green is worse than no test, because it reads as cover.
    #
    # ⚖️ The real guard is `Core.ScheduledDutyPairingTest`, which reads the
    # workflow and refuses a duty that was taken off the crontab without a
    # workflow invoking it. That is a fact about the SCHEDULE rather than about
    # the module, which is the thing in question — and the compiler already
    # defends the function's existence.
    #
    # ⚠️ Kept as a pointer rather than deleted outright, so the next person
    # looking for this job's schedule finds where it is asserted.
    test "its schedule is asserted by the duty-pairing guard, not here" do
      pairing = Path.expand("../../core/scheduled_duty_pairing_test.exs", __DIR__)

      assert File.exists?(pairing)

      assert File.read!(pairing) =~ "Stacks.Release.sweep_llm_call_log",
             "the retention sweep is not in the duty-pairing guard's roster, so nothing " <>
               "checks that a workflow actually runs it — which is how a 30-day promise " <>
               "goes unmet for 151 days with every gate green"
    end
  end
end
