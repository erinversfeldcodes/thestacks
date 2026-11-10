defmodule Stacks.Workers.RefreshCostsJobTest do
  @moduledoc "Tests for Stacks.Workers.RefreshCostsJob."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Transparency.MockPrometheusClient
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
      # ⛔ THIS TEST WAS SATISFIED BY A ZERO, and its failure message asserted
      # something untrue. `MockPrometheusClient.query/1` returns `{:ok, 0.0}`
      # when nothing has called `put_response/1`, and this file never did — so
      # `gpu_cold_starts` was 0, the idle line was `rate_card` over 0 cents,
      # `basis != "absent"` held for a count of nothing, and the message
      # claimed "the test metric store had a count" when it had none.
      #
      # ⚖️ Worse than a weak assertion: with 0 containers the whole arithmetic
      # was unexercised, so `3_060` could have been `306` and this stayed
      # green while the public money figure moved by 10x.
      MockPrometheusClient.put_response({:ok, 4.0})

      assert :ok = perform_job(RefreshCostsJob, %{})

      idle =
        Stacks.Costs.current_period_costs()
        |> Enum.find(&(&1.service == "Modal GPU Idle"))

      assert idle, "no Modal GPU Idle line was inserted at all"

      assert idle.basis != "absent",
             "the idle line rendered as unmeasured while the test metric store had a count — " <>
               "`gpu_cold_starts` is not reaching `build_cost_items/4`, so the whole idle " <>
               "costing is built and unreachable"

      # ⛔ THE ARITHMETIC, WRITTEN OUT. 4 containers x 300s = 1,200 GPU-seconds
      # of idle; at 3,060 micro-cents per second that is 3,672,000 micro-cents
      # = 36 cents. Spelled rather than derived, because an expectation that
      # reads `a10g_micro_cents_per_second/0` agrees with whatever that
      # constant says — including a wrong one. This is the same rule the Modal
      # surcharge test states, applied to the figure it was missing from.
      assert idle.amount_cents == 36,
             "4 cold starts x 300s x $0.000306/s is 36 cents; got #{idle.amount_cents}. A " <>
               "mismatch here is the unit error that the per-second rate exists to avoid"

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
