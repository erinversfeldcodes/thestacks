defmodule Stacks.Workers.ScoreSourceJobTest do
  @moduledoc "Tests for the ScoreSourceJob Oban worker."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.AI.MockTogetherClient
  alias Stacks.AI.Spend
  alias Stacks.Enrichment.DiscoveredSource
  alias Stacks.Workers.ScoreSourceJob

  describe "perform/1" do
    test "an in-range score is parsed out of the LLM's text and persisted as a float" do
      for text <- ["0.85", "0.95", "0.2", " 0.7\n"] do
        source = insert(:discovered_source)
        MockTogetherClient.put_response({:ok, text})

        assert :ok =
                 perform_job(ScoreSourceJob, %{
                   "source_id" => source.id
                 })

        updated = Core.Repo.get!(DiscoveredSource, source.id)

        assert updated.confidence == text |> String.trim() |> String.to_float(),
               "the LLM answered #{inspect(text)}; the source scored #{inspect(updated.confidence)}"
      end
    end

    test "defaults to 0.5 when LLM response is not a number" do
      source = insert(:discovered_source)
      MockTogetherClient.put_response({:ok, "This is not a number"})

      assert :ok =
               perform_job(ScoreSourceJob, %{
                 "source_id" => source.id
               })

      updated = Core.Repo.get!(DiscoveredSource, source.id)
      assert updated.confidence == 0.5
    end

    test "clamps confidence to 1.0 if above range" do
      source = insert(:discovered_source)
      MockTogetherClient.put_response({:ok, "1.5"})

      assert :ok =
               perform_job(ScoreSourceJob, %{
                 "source_id" => source.id
               })

      updated = Core.Repo.get!(DiscoveredSource, source.id)
      assert updated.confidence == 1.0
    end

    test "clamps confidence to 0.0 if below range" do
      source = insert(:discovered_source)
      MockTogetherClient.put_response({:ok, "-0.5"})

      assert :ok =
               perform_job(ScoreSourceJob, %{
                 "source_id" => source.id
               })

      updated = Core.Repo.get!(DiscoveredSource, source.id)
      assert updated.confidence == 0.0
    end

    test "returns cancel when source not found" do
      assert {:cancel, "source not found"} =
               perform_job(ScoreSourceJob, %{
                 "source_id" => Ecto.UUID.generate()
               })
    end

    test "returns error when LLM fails" do
      source = insert(:discovered_source)
      MockTogetherClient.put_response({:error, :circuit_open})

      assert {:error, :circuit_open} =
               perform_job(ScoreSourceJob, %{
                 "source_id" => source.id
               })
    end
  end

  describe "the together budget" do
    setup do
      Application.put_env(:core, :daily_limit_cents, 500)
      Application.put_env(:core, :monthly_limit_cents, 5_000)

      on_exit(fn ->
        Application.delete_env(:core, :daily_limit_cents)
        Application.delete_env(:core, :monthly_limit_cents)
      end)

      :ok
    end

    # ⛔ THE DEFECT: THIS PATH SPENT MONEY AND WAS METERED NOWHERE.
    # `BudgetTracker` had exactly one caller — `Stacks.AI.Client` passing
    # `:modal` — so every Together completion ran with no ceiling and left no
    # record of what it had cost.
    test "a completion is recorded against the together budget" do
      source = insert(:discovered_source)
      MockTogetherClient.put_response({:ok, "0.8"})

      assert Spend.spent(:together, :daily) == 0

      perform_job(ScoreSourceJob, %{"source_id" => source.id})

      assert Spend.spent(:together, :daily) > 0,
             "the call was made and nothing was charged for it — which is the state " <>
               "this path was in: billable, and invisible"
    end

    # ⚠️ AND THE CEILING MUST ACTUALLY STOP THE SPEND. Recording a cost without
    # refusing at the limit is a meter, not a budget — it would tell you
    # afterwards how much you had overspent.
    test "a spent budget stops the call being made" do
      source = insert(:discovered_source)
      MockTogetherClient.put_response({:ok, "0.8"})

      :ok = Spend.record(:together, 600)

      assert {:cancel, :daily_limit_exceeded} =
               perform_job(ScoreSourceJob, %{"source_id" => source.id})

      assert Spend.spent(:together, :daily) == 600,
             "a refused request must not be charged for"
    end

    # ⚖️ CANCELLED, NOT FAILED. A budget ceiling is not a transient fault: a
    # `{:error, _}` is what Oban retries, so returning one would burn every
    # attempt against a limit that cannot move until the period does.
    test "a refusal is cancelled rather than retried" do
      source = insert(:discovered_source)
      MockTogetherClient.put_response({:ok, "0.8"})

      :ok = Spend.record(:together, 600)

      assert {:cancel, _} = perform_job(ScoreSourceJob, %{"source_id" => source.id})
    end
  end
end
