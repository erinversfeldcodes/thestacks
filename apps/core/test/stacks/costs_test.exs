defmodule Stacks.CostsTest do
  @moduledoc "Tests for the Stacks.Costs context."

  use Core.DataCase, async: true

  alias Stacks.Costs
  alias Stacks.Costs.PlatformCost

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
    test "returns a complete breakdown map" do
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
      assert is_list(breakdown.line_items)
      assert breakdown.total_cents == 500
      assert breakdown.currency == "USD"
      assert is_float(breakdown.cost_per_book)
      assert is_integer(breakdown.book_count)
      assert is_list(breakdown.monthly_totals)
      assert %DateTime{} = breakdown.generated_at
    end

    test "returns zero cost_per_book when no books exist" do
      breakdown = Costs.cost_breakdown()
      assert breakdown.cost_per_book == 0.0
      assert breakdown.book_count == 0
    end
  end

  describe "book_count/0" do
    test "returns 0 when no books exist" do
      assert Costs.book_count() == 0
    end
  end
end
