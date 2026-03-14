defmodule Stacks.Costs do
  @moduledoc """
  Context for platform cost transparency.

  Manages infrastructure cost line items stored in `op.platform_costs`.
  All data is aggregate platform operational costs — no user data is
  ever stored or exposed through this context.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Costs.PlatformCost

  @doc """
  Returns all cost line items for the current billing period (current calendar month).

  Results are ordered by category, then service name.
  """
  @spec current_period_costs() :: [PlatformCost.t()]
  def current_period_costs do
    now = DateTime.utc_now()
    period_start = beginning_of_month(now)
    period_end = end_of_month(now)

    PlatformCost
    |> where(
      [c],
      c.period_start >= ^period_start and c.period_end <= ^period_end
    )
    |> order_by([c], [c.category, c.service])
    |> Repo.all()
  end

  @doc """
  Returns cost line items grouped by month for the last `months` months.

  Each entry is a map with `:period_start`, `:period_end`, and `:total_cents`.
  Used for the historical trend visualisation.
  """
  @spec monthly_totals(pos_integer()) :: [map()]
  def monthly_totals(months \\ 6) do
    cutoff =
      DateTime.utc_now()
      |> beginning_of_month()
      |> DateTime.add(-months * 31 * 24 * 3600, :second)

    PlatformCost
    |> where([c], c.period_start >= ^cutoff)
    |> group_by([c], [c.period_start, c.period_end])
    |> select([c], %{
      period_start: c.period_start,
      period_end: c.period_end,
      total_cents: sum(c.amount_cents)
    })
    |> order_by([c], c.period_start)
    |> Repo.all()
  end

  @doc """
  Returns the total number of books in the system, used to calculate cost-per-book.
  """
  @spec book_count() :: non_neg_integer()
  def book_count do
    Repo.one(from(b in "books", prefix: "op", select: count(b.id))) || 0
  end

  @doc """
  Upserts a cost line item. If a record with the same service and period
  already exists, it updates the amount and description.

  Returns `{:ok, cost}` or `{:error, changeset}`.
  """
  @spec upsert_cost(map()) :: {:ok, PlatformCost.t()} | {:error, Ecto.Changeset.t()}
  def upsert_cost(attrs) do
    %PlatformCost{}
    |> PlatformCost.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:amount_cents, :description, :updated_at]},
      conflict_target: [:service, :period_start, :period_end]
    )
  end

  @doc """
  Builds the public cost breakdown response map.

  Contains current period line items, monthly totals, and cost-per-book.
  No user data is included.
  """
  @spec cost_breakdown() :: map()
  def cost_breakdown do
    costs = current_period_costs()
    totals = monthly_totals()
    books = book_count()

    current_total = Enum.reduce(costs, 0, fn c, acc -> acc + c.amount_cents end)

    cost_per_book =
      if books > 0,
        do: Float.round(current_total / books / 100, 2),
        else: 0.0

    %{
      line_items: Enum.map(costs, &serialize_cost/1),
      total_cents: current_total,
      currency: "USD",
      cost_per_book: cost_per_book,
      book_count: books,
      monthly_totals: Enum.map(totals, &serialize_monthly_total/1),
      generated_at: DateTime.utc_now()
    }
  end

  defp serialize_cost(%PlatformCost{} = cost) do
    %{
      category: cost.category,
      service: cost.service,
      description: cost.description,
      amount_cents: cost.amount_cents,
      currency: cost.currency,
      period_start: DateTime.to_iso8601(cost.period_start),
      period_end: DateTime.to_iso8601(cost.period_end)
    }
  end

  defp serialize_monthly_total(%{} = total) do
    %{
      period_start: DateTime.to_iso8601(total.period_start),
      period_end: DateTime.to_iso8601(total.period_end),
      total_cents: total.total_cents
    }
  end

  defp beginning_of_month(%DateTime{} = dt) do
    %{dt | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp end_of_month(%DateTime{} = dt) do
    days = Calendar.ISO.days_in_month(dt.year, dt.month)
    %{dt | day: days, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
  end
end
