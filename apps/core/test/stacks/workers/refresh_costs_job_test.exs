defmodule Stacks.Workers.RefreshCostsJobTest do
  @moduledoc "Tests for Stacks.Workers.RefreshCostsJob."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Workers.RefreshCostsJob

  describe "perform/1" do
    test "inserts cost line items and returns :ok" do
      assert :ok = perform_job(RefreshCostsJob, %{})

      costs = Stacks.Costs.current_period_costs()
      assert length(costs) == 11

      services = Enum.map(costs, & &1.service)
      assert "Fly.io Core" in services
      assert "Fly.io Services" in services
      assert "Together AI" in services
      assert "Resend" in services
      assert "Brave Search API" in services
      assert "Google Books & Open Library" in services
      assert "Axiom" in services
      assert "Modal GPU Inference" in services
      assert "Neon PostgreSQL" in services
      assert "Domain Registration" in services
      assert "Modal GPU Idle" in services
    end

    # ⛔ THE JOB IS WHERE THE IDLE LINE GETS ITS NUMBER, AND IT WAS THE LAST
    # THING WIRED. Every other piece — the builder clause, the billed-window
    # model, the published rate, the counter, the dashboard panel — existed
    # while the page still rendered "not yet measured", because no caller
    # passed the count through. The test above would have stayed green through
    # all of it: the line is PRESENT either way, and only its basis differs.
    #
    # ⚖️ So this asserts the basis, which is the only thing that distinguishes
    # "wired" from "built". A mocked metric store returns a count here, so an
    # absent basis means the opt is not being supplied — not that the meter is
    # empty.
    test "the idle line carries a figure, not an absence, once the job supplies the count" do
      assert :ok = perform_job(RefreshCostsJob, %{})

      idle =
        Stacks.Costs.current_period_costs()
        |> Enum.find(&(&1.service == "Modal GPU Idle"))

      assert idle, "no Modal GPU Idle line was inserted at all"

      assert idle.basis != "absent",
             "the idle line rendered as unmeasured while the test metric store had a count — " <>
               "`gpu_cold_starts` is not reaching `build_cost_items/4`, so the whole idle " <>
               "costing is built and unreachable"

      assert idle.basis == "rate_card",
             "idle is a published GPU rate times a derived second count, so it is rate_card. " <>
               "MEASURED would claim it was read from a meter, which is the exact dishonesty " <>
               "the basis vocabulary was added to remove"
    end

    test "is idempotent — running twice does not duplicate records" do
      assert :ok = perform_job(RefreshCostsJob, %{})
      assert :ok = perform_job(RefreshCostsJob, %{})

      costs = Stacks.Costs.current_period_costs()
      assert length(costs) == 11
    end

    test "emits costs.refreshed event" do
      before_count = event_count("costs.refreshed")

      perform_job(RefreshCostsJob, %{})

      assert event_count("costs.refreshed") == before_count + 1
    end
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end
end
