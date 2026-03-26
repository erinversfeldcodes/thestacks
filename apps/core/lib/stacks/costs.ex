defmodule Stacks.Costs do
  @moduledoc """
  Context for platform cost transparency.

  Manages infrastructure cost line items stored in `op.platform_costs` and
  computes real usage metrics from the database for consumer-friendly cost
  breakdowns. All data is aggregate platform operational costs — no user
  data is ever stored or exposed through this context.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Oban.Job
  alias Stacks.Accounts.User
  alias Stacks.Books.{Book, UploadedImage}
  alias Stacks.Costs.PlatformCost
  alias Stacks.Shelving.Placement

  # ── Cost Queries ──────────────────────────────────────────────────────────

  @doc """
  Returns all cost line items for the current billing period (current calendar month).
  """
  @spec current_period_costs() :: [PlatformCost.t()]
  def current_period_costs do
    now = DateTime.utc_now()
    period_start = beginning_of_month(now)
    period_end = end_of_month(now)

    PlatformCost
    |> where([c], c.period_start >= ^period_start and c.period_end <= ^period_end)
    |> order_by([c], [c.category, c.service])
    |> Repo.all()
  end

  @doc """
  Returns cost line items grouped by month for the last `months` months.
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

  # ── Usage Metrics (real data from DB) ─────────────────────────────────────

  @doc """
  Returns platform usage metrics derived from actual database contents.
  These power the consumer-friendly cost explanations.
  """
  @spec usage_metrics() :: map()
  def usage_metrics do
    %{
      books: book_count(),
      uploads: upload_count(),
      placements: placement_count(),
      db_size_bytes: db_size_bytes(),
      avg_upload_payload_bytes: avg_upload_payload_bytes(),
      vision_jobs_this_month: vision_jobs_this_month()
    }
  end

  @doc "Total books in the system."
  @spec book_count() :: non_neg_integer()
  def book_count do
    Repo.one(from(b in Book, select: count(b.id))) || 0
  end

  @doc "Total registered users."
  @spec user_count() :: non_neg_integer()
  def user_count do
    Repo.one(from(u in User, select: count(u.id))) || 0
  end

  @doc "Total uploaded images."
  @spec upload_count() :: non_neg_integer()
  def upload_count do
    Repo.one(from(i in UploadedImage, select: count(i.id))) || 0
  end

  @doc "Total bookshelf placements."
  @spec placement_count() :: non_neg_integer()
  def placement_count do
    Repo.one(from(p in Placement, select: count(p.id))) || 0
  end

  @doc "Database size in bytes (pg_database_size)."
  @spec db_size_bytes() :: non_neg_integer()
  def db_size_bytes do
    case Repo.query("SELECT pg_database_size(current_database())") do
      {:ok, %{rows: [[size]]}} when is_integer(size) -> size
      _ -> 0
    end
  end

  @doc "Average size of vision job payloads in bytes (proxy for image size)."
  @spec avg_upload_payload_bytes() :: non_neg_integer()
  def avg_upload_payload_bytes do
    result =
      Repo.one(
        from(j in Job,
          where: j.queue == "vision",
          select: fragment("coalesce(avg(octet_length(?::text))::bigint, 0)", j.args)
        )
      )

    result || 0
  end

  @doc "Number of vision inference jobs completed this month."
  @spec vision_jobs_this_month() :: non_neg_integer()
  def vision_jobs_this_month do
    month_start = beginning_of_month(DateTime.utc_now())

    Repo.one(
      from(j in Job,
        where: j.queue == "vision" and j.inserted_at >= ^month_start,
        select: count(j.id)
      )
    ) || 0
  end

  # ── Changesets ────────────────────────────────────────────────────────────

  @platform_cost_valid_categories ~w(hosting compute database domain)

  @doc "Changeset for creating or updating a platform cost line item."
  def platform_cost_changeset(cost, attrs) do
    cost
    |> cast(attrs, [
      :category,
      :service,
      :description,
      :amount_cents,
      :currency,
      :period_start,
      :period_end
    ])
    |> validate_required([
      :category,
      :service,
      :amount_cents,
      :currency,
      :period_start,
      :period_end
    ])
    |> validate_inclusion(:category, @platform_cost_valid_categories)
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:service, :period_start, :period_end])
  end

  # ── Upsert ────────────────────────────────────────────────────────────────

  @doc """
  Upserts a cost line item. If a record with the same service and period
  already exists, it updates the amount and description.
  """
  @spec upsert_cost(map()) :: {:ok, PlatformCost.t()} | {:error, Ecto.Changeset.t()}
  def upsert_cost(attrs) do
    result =
      %PlatformCost{}
      |> platform_cost_changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:amount_cents, :description, :updated_at]},
        conflict_target: [:service, :period_start, :period_end]
      )

    case result do
      {:ok, cost} ->
        :telemetry.execute(
          [:stacks, :costs, :recorded],
          %{amount_cents: cost.amount_cents},
          %{category: cost.category, service: cost.service}
        )

      _ ->
        :ok
    end

    result
  end

  # ── Public Breakdown ──────────────────────────────────────────────────────

  @doc """
  Builds the full public cost breakdown response with real usage metrics.
  No user data is included — only aggregate platform stats.
  """
  @spec cost_breakdown() :: map()
  def cost_breakdown do
    costs = current_period_costs()
    totals = monthly_totals()
    metrics = usage_metrics()

    current_total = Enum.reduce(costs, 0, fn c, acc -> acc + c.amount_cents end)

    cost_per_book =
      if metrics.books > 0,
        do: Float.round(current_total / metrics.books / 100, 2),
        else: 0.0

    by_category =
      costs
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {category, items} ->
        %{
          category: category,
          total_cents: Enum.reduce(items, 0, fn c, acc -> acc + c.amount_cents end),
          items: Enum.map(items, &serialize_cost/1)
        }
      end)
      |> Enum.sort_by(& &1.total_cents, :desc)

    %{
      total_cents: current_total,
      currency: "USD",
      cost_per_book: cost_per_book,
      categories: by_category,
      metrics: metrics,
      monthly_totals: Enum.map(totals, &serialize_monthly_total/1),
      generated_at: DateTime.utc_now()
    }
  end

  defp serialize_cost(%PlatformCost{} = cost) do
    %{
      service: cost.service,
      description: cost.description,
      amount_cents: cost.amount_cents
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
