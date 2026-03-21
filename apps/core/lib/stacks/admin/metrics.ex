defmodule Stacks.Admin.Metrics do
  @moduledoc """
  Context for the admin metrics dashboard.

  Reads from dbt mart views in the `wh` schema. All queries use `Repo.query/1`
  with `rescue` fallback so that the metrics API works even when mart views
  have not been created yet (parallel development with Issue #052).
  """

  alias Core.Repo

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
          total_books: count_table("books"),
          total_users: count_table("users"),
          total_placements: count_table("bookshelf_placements"),
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

  Falls back to empty list when the mart does not exist.
  """
  @spec quality_trends() :: [map()]
  def quality_trends do
    case query_mart_rows("SELECT * FROM wh.mart_data_quality_trend ORDER BY week_start") do
      rows when is_list(rows) and rows != [] -> rows
      _ -> []
    end
  end

  # ── Source Health ───────────────────────────────────────────────────────────

  @doc """
  Returns per-source health status from `wh.int_source_health`.

  Falls back to querying `op.source_health_checks` when the intermediate
  view does not exist.
  """
  @spec source_health() :: [map()]
  def source_health do
    query_mart_rows(
      "SELECT source_name, source_type, status, consecutive_failures, total_successes, total_failures FROM op.source_health_checks ORDER BY source_name"
    )
  end

  # ── Enrichment Gaps ────────────────────────────────────────────────────────

  @doc """
  Returns enrichment gap counts from `wh.mart_enrichment_gaps`.

  Falls back to empty data when the mart does not exist.
  """
  @spec enrichment_gaps() :: map()
  def enrichment_gaps do
    case query_mart("SELECT * FROM wh.mart_enrichment_gaps LIMIT 1") do
      {:ok, row} -> row
      :fallback -> %{status: "mart_not_available", gaps: []}
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

  defp count_table(table_name) do
    case Repo.query("SELECT count(*) FROM op.#{table_name}") do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp count_pending_images do
    case Repo.query(
           "SELECT count(*) FROM op.uploaded_images WHERE status = 'pending' AND expires_at < now()"
         ) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp count_consented_users do
    case Repo.query("SELECT count(*) FROM op.users WHERE consent_analytics = true") do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end
end
