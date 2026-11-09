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

  describe "it is reachable" do
    # ⛔ A JOB NOTHING CALLS IS A JOB THAT DOES NOT RUN. This project has shipped
    # a runner proven working and invoked by nobody; naming the caller is what
    # separates "it works" from "it happens".
    test "a release duty invokes it" do
      Code.ensure_loaded!(Stacks.Release)

      assert function_exported?(Stacks.Release, :sweep_llm_call_log, 0),
             "the sweep has no scheduled caller, so the retention policy only runs when " <>
               "someone remembers to run it"
    end
  end
end
