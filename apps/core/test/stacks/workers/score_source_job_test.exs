defmodule Stacks.Workers.ScoreSourceJobTest do
  @moduledoc "Tests for the ScoreSourceJob Oban worker."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.AI.MockTogetherClient
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
end
