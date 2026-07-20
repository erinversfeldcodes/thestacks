defmodule Stacks.CostsTest do
  @moduledoc "Tests for the Stacks.Costs context."

  # async: false — the telemetry emission test (Layer 11) attaches a GLOBAL
  # :telemetry handler and asserts an EXACT event count. A concurrently-running
  # async module that also calls upsert_cost (e.g. RefreshCostsJob) would emit
  # the same [:stacks, :costs, :recorded] event and inflate that count. Running
  # sync guarantees no other test emits into our handler. Mirrors the
  # async: false choice in observability_telemetry_test.exs / upload_telemetry_test.exs.
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Costs
  alias Stacks.Costs.PlatformCost

  # ── Telemetry helpers (mirrors observability_telemetry_test.exs) ──────────

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

  # Collect exactly `n` [:stacks, :costs, :recorded] events, returning
  # {measurements, metadata} tuples. Fails (via assert_receive) if fewer arrive.
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

  describe "build_cost_items/3" do
    # Single source of truth (Issue #259): both RefreshCostsJob and
    # seed_current_period_costs/0 build their items via this function, so this
    # pins the shared definition both callers depend on.
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

    test "with vision_jobs 0 yields the 5 seeded line items summing to 1168", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 0)

      assert length(items) == 5

      assert Enum.map(items, & &1.category) == ~w(hosting hosting compute database domain)
      assert Enum.map(items, & &1.amount_cents) == [534, 534, 0, 0, 100]
      assert Enum.reduce(items, 0, fn i, acc -> acc + i.amount_cents end) == 1168

      # Every item carries the shared period + currency envelope.
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
  end

  describe "seed_current_period_costs/0" do
    # Guards the E2E cost-data fixture (Issue #110): seeds.exs calls this so
    # preview/local deploys always have current-period cost data for the costs
    # page E2E. The 5 static line items mirror RefreshCostsJob with Modal at 0
    # inferences (amount_cents 0), summing to 1168 cents.
    #
    # Same current-calendar-month window as Costs.current_period_costs/0.
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

    test "seeded items sum to a positive total (1168 cents with Modal at 0)" do
      Costs.seed_current_period_costs()

      total_cents =
        Costs.current_period_costs()
        |> Enum.reduce(0, fn c, acc -> acc + c.amount_cents end)

      # Static items: Fly.io Core 534 + Fly.io Vision 534 + Modal 0 (0 inferences)
      # + Neon 0 + Domain 100 = 1168.
      assert total_cents > 0
      assert total_cents == 1168
    end

    test "every seeded row's period lies inside the current calendar month" do
      Costs.seed_current_period_costs()

      month_start = beginning_of_current_month()
      month_end = end_of_current_month()

      # Anti-regression guard: if the period formula ever drifts so rows fall
      # outside current_period_costs/0's month window, the E2E silently reverts
      # to empty-state. Query the RAW table (not the already-month-filtered
      # current_period_costs/0 view, which would exclude any drifted row upstream
      # and make this loop pass vacuously). The seed sets every row to precisely
      # beginning/end-of-month, so :eq is the tightest correct assertion, and the
      # length check keeps the loop non-empty so :eq actually fires.
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
    # Characterization test: upsert_cost/1 fires [:stacks, :costs, :recorded] on
    # each {:ok, cost} (costs.ex), and seed_current_period_costs/0 upserts the 5
    # static line items, so seeding must emit EXACTLY 5 such events. A count of 5
    # (not >= 1) is the load-bearing check: a partial-seed regression — a builder
    # that drops a line item, or an upsert that starts silently failing — would
    # emit fewer than 5 and fail here. Module is async: false so no concurrent
    # emitter can inflate the count.
    test "emits exactly 5 [:stacks, :costs, :recorded] events, one per line item" do
      attach_telemetry([[:stacks, :costs, :recorded]])

      Costs.seed_current_period_costs()

      events = collect_costs_events(5)
      assert length(events) == 5

      # Exactly 5 — a 6th event (over-seed regression) must not arrive.
      refute_receive {:telemetry_event, [:stacks, :costs, :recorded], _, _}, 50

      # Each event carries an amount_cents measurement + category/service metadata.
      for {measurements, metadata} <- events do
        assert is_integer(measurements.amount_cents)
        assert is_binary(metadata.category)
        assert is_binary(metadata.service)
      end

      # The 5 events correspond to the 5 distinct seeded services.
      services = Enum.map(events, fn {_m, metadata} -> metadata.service end)

      assert Enum.sort(services) ==
               Enum.sort([
                 "Fly.io Core",
                 "Fly.io Vision Sidecar",
                 "Modal GPU Inference",
                 "Neon PostgreSQL",
                 "Domain Registration"
               ])
    end
  end

  describe "current_period_costs/0 month scoping (Layer 13)" do
    # Characterization test pinning BOTH directions of the current-calendar-month
    # filter (costs.ex — period_start >= beginning_of_month and
    # period_end <= end_of_month): a current-month row is INCLUDED and a
    # prior-month row is EXCLUDED. This documents the known preview
    # month-boundary limitation (data seeded for the current month only) as
    # intended behaviour — a regression that widened or dropped the window would
    # flip one of these assertions.
    test "includes current-month rows and excludes a prior-month row" do
      now = DateTime.utc_now()

      # Prior calendar month, computed robustly across the January→December
      # (prior-year) boundary — never by naive day subtraction.
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

      # Prior-month row inserted DIRECTLY (never via seed_current_period_costs/0,
      # which always stamps the current month). Valid category + amount >= 0.
      prior_row =
        insert(:platform_cost,
          category: "hosting",
          service: "Prior Month Service",
          amount_cents: 999,
          currency: "USD",
          period_start: prior_start,
          period_end: prior_end
        )

      # Current-month rows via the seed fixture (all stamped to this month).
      Costs.seed_current_period_costs()

      costs = Costs.current_period_costs()
      services = Enum.map(costs, & &1.service)

      # Prior-month row is EXCLUDED (both by service and by id).
      refute "Prior Month Service" in services
      refute Enum.any?(costs, &(&1.id == prior_row.id))

      # Current-month rows are INCLUDED.
      assert "Fly.io Core" in services
      assert length(costs) == 5
    end
  end
end
