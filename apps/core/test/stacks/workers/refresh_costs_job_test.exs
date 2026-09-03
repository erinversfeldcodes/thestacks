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
      assert length(costs) == 10

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
    end

    test "is idempotent — running twice does not duplicate records" do
      assert :ok = perform_job(RefreshCostsJob, %{})
      assert :ok = perform_job(RefreshCostsJob, %{})

      costs = Stacks.Costs.current_period_costs()
      assert length(costs) == 10
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
