defmodule Stacks.Admin.Metrics do
  @moduledoc """
  Context for the admin metrics dashboard.

  Reads from dbt mart views in the `wh` schema. All queries use `Repo.query/1`
  with `rescue` fallback so that the metrics API works even when mart views
  have not been created yet (parallel development with Issue #052).
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Books.{Book, UploadedImage}
  alias Stacks.Shelving.Placement

  require Logger

  # ── System Health ──────────────────────────────────────────────────────────

  @doc """
  Returns system health metrics from `wh.mart_system_health`.

  Falls back to live database queries when the mart view does not exist.
  """
  @spec system_health() :: map()
  def system_health do
    case query_mart("SELECT * FROM wh.mart_system_health LIMIT 1") do
      {:ok, row} ->
        row

      :fallback ->
        %{
          db_size_bytes: db_size_bytes(),
          total_books: Repo.aggregate(Book, :count),
          total_users: Repo.aggregate(User, :count),
          total_placements: Repo.aggregate(Placement, :count),
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  # ── Job Stats ──────────────────────────────────────────────────────────────

  @doc """
  Returns per-queue Oban job statistics from `wh.mart_job_stats`.

  Falls back to a live query against `public.oban_jobs` when the mart does not exist.
  """
  @spec job_stats() :: [map()]
  def job_stats do
    case query_mart_rows(
           "SELECT queue, state, count(*) as count FROM public.oban_jobs GROUP BY queue, state ORDER BY queue, state"
         ) do
      rows when is_list(rows) and rows != [] ->
        rows

      _ ->
        []
    end
  end

  # ── Data Freshness ─────────────────────────────────────────────────────────

  @doc """
  Returns data freshness metrics from `wh.mart_data_freshness`.

  Falls back to empty data when the mart does not exist.
  """
  @spec data_freshness() :: map()
  def data_freshness do
    case query_mart("SELECT * FROM wh.mart_data_freshness LIMIT 1") do
      {:ok, row} -> row
      :fallback -> %{status: "mart_not_available", categories: []}
    end
  end

  # ── Cost Breakdown ─────────────────────────────────────────────────────────

  @doc """
  Returns cost tracking data. Delegates to `Stacks.Costs.cost_breakdown/0`
  since that context already has full cost data.
  """
  @spec cost_breakdown() :: map()
  def cost_breakdown do
    Stacks.Costs.cost_breakdown()
  end

  # ── GDPR Compliance ────────────────────────────────────────────────────────

  @doc """
  Returns GDPR compliance metrics from `wh.mart_gdpr_compliance`.

  Falls back to live queries when the mart does not exist.
  """
  @spec gdpr_compliance() :: map()
  def gdpr_compliance do
    case query_mart("SELECT * FROM wh.mart_gdpr_compliance LIMIT 1") do
      {:ok, row} ->
        row

      :fallback ->
        %{
          images_pending_deletion: count_pending_images(),
          users_with_consent: count_consented_users(),
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  # ── Quality Trends ─────────────────────────────────────────────────────────

  @doc """
  Returns 12-week quality trend sparkline data from `wh.mart_data_quality_trend`.

  Falls back to a live current-snapshot aggregation over op tables (books, editions,
  price/review snapshots) when the mart view does not exist, mirroring
  `mart_data_quality_trend.sql`'s daily snapshot. A single current-day point is
  returned when no historical mart is present.
  """
  @spec quality_trends() :: [map()]
  def quality_trends do
    case query_mart_rows("SELECT * FROM wh.mart_data_quality_trend ORDER BY snapshot_date") do
      rows when is_list(rows) and rows != [] -> rows
      _ -> live_quality_snapshot()
    end
  end

  # ── Source Health ───────────────────────────────────────────────────────────

  @doc """
  Returns per-source health status from `op.source_health_checks`.

  Emits the wire shape the frontend `getSourceHealth` decoder (#261) consumes:
  `{name, source_type, status, consecutive_failures, last_success_at, last_failure_at}`
  with plain-string `source_type`/`status` (NOT proto enums) and ISO8601-or-nil
  timestamps. `source_name` is remapped to the `name` key the decoder reads.
  """
  @spec source_health() :: [map()]
  def source_health do
    "SELECT source_name, source_type, status, consecutive_failures, last_success_at, last_failure_at FROM op.source_health_checks ORDER BY source_name"
    |> query_mart_rows()
    |> Enum.map(&to_source_health_wire/1)
  end

  defp to_source_health_wire(row) do
    %{
      name: row["source_name"],
      source_type: row["source_type"],
      status: row["status"],
      consecutive_failures: row["consecutive_failures"],
      last_success_at: iso8601(row["last_success_at"]),
      last_failure_at: iso8601(row["last_failure_at"])
    }
  end

  # ── Enrichment Gaps ────────────────────────────────────────────────────────

  @doc """
  Returns enrichment gap counts from `wh.mart_enrichment_gaps`.

  Falls back to a live aggregation over op tables (books, editions, price/review
  snapshots) when the mart view does not exist, mirroring `mart_enrichment_gaps.sql`
  but querying op tables directly (never the `int_*` dbt intermediates).
  """
  @spec enrichment_gaps() :: map()
  def enrichment_gaps do
    case query_mart("SELECT * FROM wh.mart_enrichment_gaps LIMIT 1") do
      {:ok, row} when map_size(row) > 0 -> row
      _ -> live_enrichment_gaps()
    end
  end

  # ── Full Dashboard ─────────────────────────────────────────────────────────

  @doc """
  Aggregates all metrics sections into a single response map.
  """
  @spec dashboard() :: map()
  def dashboard do
    %{
      system_health: system_health(),
      job_stats: job_stats(),
      data_freshness: data_freshness(),
      costs: cost_breakdown(),
      gdpr: gdpr_compliance(),
      quality_trends: quality_trends(),
      source_health: source_health(),
      enrichment_gaps: enrichment_gaps(),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Live-query fallback for enrichment_gaps/0 — aggregates cover/price/review gaps
  # over op tables. A book "has a cover" when any of its editions carries a
  # cover_image_url (covers live on op.book_editions, not op.books — Works/Editions
  # model). Mirrors mart_enrichment_gaps.sql without joining the int_* dbt views.
  defp live_enrichment_gaps do
    sql = """
    SELECT
      count(*) AS total_books,
      count(*) FILTER (
        WHERE NOT EXISTS (
          SELECT 1 FROM op.book_editions e
          WHERE e.book_id = b.id AND e.cover_image_url IS NOT NULL
        )
      ) AS missing_cover,
      count(*) FILTER (
        WHERE NOT EXISTS (SELECT 1 FROM op.price_snapshots p WHERE p.book_id = b.id)
      ) AS missing_prices,
      count(*) FILTER (
        WHERE NOT EXISTS (SELECT 1 FROM op.review_snapshots r WHERE r.book_id = b.id)
      ) AS missing_reviews
    FROM op.books b
    """

    case query_mart(sql) do
      {:ok, row} when map_size(row) > 0 ->
        %{
          status: "live",
          total_books: to_int(row["total_books"]),
          missing_cover: to_int(row["missing_cover"]),
          missing_prices: to_int(row["missing_prices"]),
          missing_reviews: to_int(row["missing_reviews"])
        }

      _ ->
        %{
          status: "live",
          total_books: 0,
          missing_cover: 0,
          missing_prices: 0,
          missing_reviews: 0
        }
    end
  end

  # Live-query fallback for quality_trends/0 — a single current-day snapshot mirroring
  # mart_data_quality_trend.sql, computed over op tables. Returns a one-element list.
  defp live_quality_snapshot do
    sql = """
    SELECT
      (SELECT count(*) FROM op.books) AS total_books,
      (
        SELECT count(*) FROM op.books b
        WHERE EXISTS (
          SELECT 1 FROM op.book_editions e
          WHERE e.book_id = b.id AND e.cover_image_url IS NOT NULL
        )
      ) AS books_with_covers,
      (SELECT count(DISTINCT p.book_id) FROM op.price_snapshots p) AS books_with_prices,
      (SELECT count(DISTINCT r.book_id) FROM op.review_snapshots r) AS books_with_reviews,
      (SELECT count(*) FROM op.source_health_checks) AS total_sources,
      (SELECT count(*) FROM op.source_health_checks WHERE status = 'healthy') AS healthy_sources
    """

    case query_mart(sql) do
      {:ok, row} when map_size(row) > 0 ->
        total = to_int(row["total_books"])
        covers = to_int(row["books_with_covers"])
        prices = to_int(row["books_with_prices"])
        reviews = to_int(row["books_with_reviews"])

        [
          %{
            snapshot_date: Date.utc_today() |> Date.to_iso8601(),
            total_books: total,
            books_with_covers: covers,
            books_with_prices: prices,
            books_with_reviews: reviews,
            total_sources: to_int(row["total_sources"]),
            healthy_sources: to_int(row["healthy_sources"]),
            cover_pct: pct(covers, total),
            price_pct: pct(prices, total),
            review_pct: pct(reviews, total)
          }
        ]

      _ ->
        []
    end
  end

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)

  defp pct(_numerator, 0), do: 0.0
  defp pct(numerator, total), do: Float.round(numerator / total * 100, 1)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp query_mart(sql) do
    case Repo.query(sql) do
      {:ok, %{rows: [row], columns: columns}} ->
        {:ok, Enum.zip(columns, row) |> Map.new()}

      {:ok, %{rows: []}} ->
        {:ok, %{}}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("Metrics mart not available: #{sql}")
        :fallback

      {:error, reason} ->
        Logger.warning("Metrics query failed: #{inspect(reason)}")
        :fallback
    end
  rescue
    e ->
      Logger.warning("Metrics query exception: #{inspect(e)}")
      :fallback
  end

  defp query_mart_rows(sql) do
    case Repo.query(sql) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          Enum.zip(columns, row) |> Map.new()
        end)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("Metrics mart not available: #{sql}")
        []

      {:error, reason} ->
        Logger.warning("Metrics query failed: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.warning("Metrics query exception: #{inspect(e)}")
      []
  end

  defp db_size_bytes do
    case Repo.query("SELECT pg_database_size(current_database())") do
      {:ok, %{rows: [[size]]}} when is_integer(size) -> size
      _ -> 0
    end
  end

  defp count_pending_images do
    now = DateTime.utc_now()

    Repo.aggregate(
      from(i in UploadedImage, where: i.status == "pending" and i.expires_at < ^now),
      :count
    )
  end

  defp count_consented_users do
    Repo.aggregate(from(u in User, where: u.consent_analytics == true), :count)
  end
end
