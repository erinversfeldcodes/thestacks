defmodule Stacks.CostsTest do
  @moduledoc "Tests for the Stacks.Costs context."

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Costs
  alias Stacks.Costs.PlatformCost

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "test-#{inspect(make_ref())}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp collect_costs_events(n) do
    for _ <- 1..n do
      assert_receive {:telemetry_event, [:stacks, :costs, :recorded], measurements, metadata}, 500
      {measurements, metadata}
    end
  end

  describe "upsert_cost/1" do
    test "inserts a new cost line item" do
      now = DateTime.utc_now()

      attrs = %{
        category: "hosting",
        service: "Fly.io Core",
        description: "Phoenix API server",
        amount_cents: 534,
        currency: "USD",
        period_start: %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}},
        period_end: %{now | day: 28, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
      }

      assert {:ok, %PlatformCost{} = cost} = Costs.upsert_cost(attrs)
      assert cost.category == "hosting"
      assert cost.service == "Fly.io Core"
      assert cost.amount_cents == 534
    end

    test "upserts on conflict — updates amount for same service and period" do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      period_end = %{now | day: 28, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}

      attrs = %{
        category: "hosting",
        service: "Fly.io Core",
        description: "Original",
        amount_cents: 500,
        currency: "USD",
        period_start: period_start,
        period_end: period_end
      }

      assert {:ok, _} = Costs.upsert_cost(attrs)

      updated_attrs = %{attrs | amount_cents: 600, description: "Updated"}
      assert {:ok, %PlatformCost{} = cost} = Costs.upsert_cost(updated_attrs)
      assert cost.amount_cents == 600
    end

    test "rejects invalid category" do
      now = DateTime.utc_now()

      attrs = %{
        category: "invalid_category",
        service: "Test",
        amount_cents: 100,
        currency: "USD",
        period_start: now,
        period_end: now
      }

      assert {:error, changeset} = Costs.upsert_cost(attrs)
      assert %{category: _} = errors_on(changeset)
    end

    test "rejects negative amount" do
      now = DateTime.utc_now()

      attrs = %{
        category: "hosting",
        service: "Test",
        amount_cents: -100,
        currency: "USD",
        period_start: now,
        period_end: now
      }

      assert {:error, changeset} = Costs.upsert_cost(attrs)
      assert %{amount_cents: _} = errors_on(changeset)
    end
  end

  describe "current_period_costs/0" do
    test "returns costs for the current month" do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      days = Calendar.ISO.days_in_month(now.year, now.month)

      period_end = %{
        now
        | day: days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      {:ok, _} =
        Costs.upsert_cost(%{
          category: "hosting",
          service: "Test Service",
          amount_cents: 100,
          currency: "USD",
          period_start: period_start,
          period_end: period_end
        })

      costs = Costs.current_period_costs()
      assert costs != []
      assert Enum.any?(costs, &(&1.service == "Test Service"))
    end

    test "returns empty list when no costs exist" do
      assert Costs.current_period_costs() == []
    end
  end

  describe "cost_breakdown/0" do
    test "returns a complete breakdown map with categories and metrics" do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      days = Calendar.ISO.days_in_month(now.year, now.month)

      period_end = %{
        now
        | day: days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      {:ok, _} =
        Costs.upsert_cost(%{
          category: "hosting",
          service: "Test",
          amount_cents: 500,
          currency: "USD",
          period_start: period_start,
          period_end: period_end
        })

      breakdown = Costs.cost_breakdown()
      assert is_list(breakdown.categories)
      assert breakdown.total_cents == 500
      assert breakdown.currency == "USD"
      assert is_float(breakdown.cost_per_book)
      assert is_map(breakdown.metrics)
      assert is_integer(breakdown.metrics.books)
      assert is_list(breakdown.monthly_totals)
      assert %DateTime{} = breakdown.generated_at
    end

    test "returns zero cost_per_book when no books exist" do
      breakdown = Costs.cost_breakdown()
      assert breakdown.cost_per_book == 0.0
      assert breakdown.metrics.books == 0
    end
  end

  describe "usage_metrics/0" do
    test "returns aggregate platform metrics without user data" do
      metrics = Costs.usage_metrics()
      assert is_integer(metrics.books)
      assert is_integer(metrics.uploads)
      assert is_integer(metrics.placements)
      assert is_integer(metrics.db_size_bytes)
      assert is_integer(metrics.avg_upload_payload_bytes)
      assert is_integer(metrics.vision_jobs_this_month)
      refute Map.has_key?(metrics, :users)
    end
  end

  describe "book_count/0" do
    test "returns 0 when no books exist" do
      assert Costs.book_count() == 0
    end
  end

  describe "build_cost_items/4" do
    setup do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      days = Calendar.ISO.days_in_month(now.year, now.month)

      period_end = %{
        now
        | day: days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      %{period_start: period_start, period_end: period_end}
    end

    test "with vision_jobs 0 yields the 5 seeded line items summing to 1660", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 0)

      assert length(items) == 5

      assert Enum.map(items, & &1.category) == ~w(hosting hosting compute database domain)
      assert Enum.map(items, & &1.amount_cents) == [534, 1026, 0, 0, 100]
      assert Enum.reduce(items, 0, fn i, acc -> acc + i.amount_cents end) == 1660

      for item <- items do
        assert item.period_start == ctx.period_start
        assert item.period_end == ctx.period_end
        assert item.currency == "USD"
      end

      modal = Enum.find(items, &(&1.service == "Modal GPU Inference"))
      assert modal.amount_cents == 0
      assert modal.description =~ "0 inferences this month"
    end

    test "with vision_jobs 7 computes the Modal item from the usage count", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 7)

      modal = Enum.find(items, &(&1.service == "Modal GPU Inference"))
      assert modal.amount_cents == 21
      assert modal.description =~ "7 inferences this month"
    end

    test "without a measurement the Fly core line is the flat estimate and says so", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 0, core_awake_seconds: nil)

      core = Enum.find(items, &(&1.service == "Fly.io Core"))
      assert core.amount_cents == 534
      assert core.description =~ "estimated flat-rate"
    end

    test "with measured awake seconds the Fly core line is proportional to awake time", ctx do
      # 42_120s awake = 11.7h; 534¢ × 42_120 / (730h × 3600) rounds to 9¢
      items =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 0, core_awake_seconds: 42_120)

      core = Enum.find(items, &(&1.service == "Fly.io Core"))
      assert core.amount_cents == 9
      assert core.description =~ "measured: awake 11.7h this period"
      refute core.description =~ "estimated flat-rate"
    end

    test "a full month awake measures back to the flat monthly rate", ctx do
      items =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 0,
          core_awake_seconds: 730 * 3600
        )

      core = Enum.find(items, &(&1.service == "Fly.io Core"))
      assert core.amount_cents == 534
    end
  end

  describe "core_awake_seconds/2" do
    alias Stacks.Transparency.MockPrometheusClient

    setup do
      MockPrometheusClient.reset()
      period_start = ~U[2026-08-01 00:00:00.000000Z]
      now = ~U[2026-08-13 12:00:00.000000Z]
      %{period_start: period_start, now: now}
    end

    test "multiplies the sample count by the push interval", ctx do
      MockPrometheusClient.put_response({:ok, 2799.0})

      assert {:ok, 41_985} = Costs.core_awake_seconds(ctx.period_start, ctx.now)

      query = MockPrometheusClient.last_query()
      assert query =~ "sum(count_over_time(stacks_fuse_state_state{"
      assert query =~ ~s|fuse_name="vision_fuse"|
      # the window is the elapsed period, not a fixed lookback
      window_s = DateTime.diff(ctx.now, ctx.period_start, :second)
      assert query =~ "[#{window_s}s]))"
    end

    test "returns :error when the metrics store is unreachable" do
      MockPrometheusClient.put_response({:error, :nxdomain})

      assert :error =
               Costs.core_awake_seconds(
                 ~U[2026-08-01 00:00:00.000000Z],
                 ~U[2026-08-13 12:00:00.000000Z]
               )
    end

    test "returns :error when the store holds no samples for the series" do
      MockPrometheusClient.put_response({:ok, 0.0})

      assert :error =
               Costs.core_awake_seconds(
                 ~U[2026-08-01 00:00:00.000000Z],
                 ~U[2026-08-13 12:00:00.000000Z]
               )
    end
  end

  describe "seed_current_period_costs/0" do
    defp beginning_of_current_month do
      now = DateTime.utc_now()
      %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
    end

    defp end_of_current_month do
      now = DateTime.utc_now()
      days = Calendar.ISO.days_in_month(now.year, now.month)
      %{now | day: days, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
    end

    test "populates current_period_costs/0 with the 5 static line items" do
      assert Costs.current_period_costs() == []

      Costs.seed_current_period_costs()

      costs = Costs.current_period_costs()
      assert costs != []
      assert length(costs) == 5
    end

    test "seeded items sum to a positive total (1660 cents with Modal at 0)" do
      Costs.seed_current_period_costs()

      total_cents =
        Costs.current_period_costs()
        |> Enum.reduce(0, fn c, acc -> acc + c.amount_cents end)

      assert total_cents > 0
      assert total_cents == 1660
    end

    test "every seeded row's period lies inside the current calendar month" do
      Costs.seed_current_period_costs()

      month_start = beginning_of_current_month()
      month_end = end_of_current_month()

      seeded_rows = Core.Repo.all(PlatformCost)
      assert length(seeded_rows) == 5

      for cost <- seeded_rows do
        assert DateTime.compare(cost.period_start, month_start) == :eq
        assert DateTime.compare(cost.period_end, month_end) == :eq
      end
    end

    test "is idempotent — running twice does not duplicate rows" do
      Costs.seed_current_period_costs()
      Costs.seed_current_period_costs()

      assert length(Costs.current_period_costs()) == 5
    end
  end

  describe "seed_current_period_costs/0 telemetry (Layer 11)" do
    test "emits exactly 5 [:stacks, :costs, :recorded] events, one per line item" do
      attach_telemetry([[:stacks, :costs, :recorded]])

      Costs.seed_current_period_costs()

      events = collect_costs_events(5)
      assert length(events) == 5

      refute_receive {:telemetry_event, [:stacks, :costs, :recorded], _, _}, 50

      for {measurements, metadata} <- events do
        assert is_integer(measurements.amount_cents)
        assert is_binary(metadata.category)
        assert is_binary(metadata.service)
      end

      services = Enum.map(events, fn {_m, metadata} -> metadata.service end)

      assert Enum.sort(services) ==
               Enum.sort([
                 "Fly.io Core",
                 "Fly.io Services",
                 "Modal GPU Inference",
                 "Neon PostgreSQL",
                 "Domain Registration"
               ])
    end
  end

  describe "current_period_costs/0 month scoping (Layer 13)" do
    test "includes current-month rows and excludes a prior-month row" do
      now = DateTime.utc_now()

      {prev_year, prev_month} =
        if now.month == 1, do: {now.year - 1, 12}, else: {now.year, now.month - 1}

      prior_days = Calendar.ISO.days_in_month(prev_year, prev_month)

      prior_start = %{
        now
        | year: prev_year,
          month: prev_month,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
          microsecond: {0, 6}
      }

      prior_end = %{
        now
        | year: prev_year,
          month: prev_month,
          day: prior_days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      prior_row =
        insert(:platform_cost,
          category: "hosting",
          service: "Prior Month Service",
          amount_cents: 999,
          currency: "USD",
          period_start: prior_start,
          period_end: prior_end
        )

      Costs.seed_current_period_costs()

      costs = Costs.current_period_costs()
      services = Enum.map(costs, & &1.service)

      refute "Prior Month Service" in services
      refute Enum.any?(costs, &(&1.id == prior_row.id))

      assert "Fly.io Core" in services
      assert length(costs) == 5
    end
  end
end
