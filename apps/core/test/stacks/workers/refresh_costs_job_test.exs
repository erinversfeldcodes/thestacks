defmodule Stacks.Workers.RefreshCostsJobTest do
  @moduledoc "Tests for Stacks.Workers.RefreshCostsJob."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Workers.RefreshCostsJob

  describe "perform/1" do
    test "inserts cost line items and returns :ok" do
      assert :ok = perform_job(RefreshCostsJob, %{})

      costs = Stacks.Costs.current_period_costs()
      assert length(costs) == 5

      services = Enum.map(costs, & &1.service)
      assert "Fly.io Core" in services
      assert "Fly.io Vision Sidecar" in services
      assert "Modal GPU Inference" in services
      assert "Neon PostgreSQL" in services
      assert "Domain Registration" in services
    end

    test "is idempotent — running twice does not duplicate records" do
      assert :ok = perform_job(RefreshCostsJob, %{})
      assert :ok = perform_job(RefreshCostsJob, %{})

      costs = Stacks.Costs.current_period_costs()
      assert length(costs) == 5
    end
  end
end
