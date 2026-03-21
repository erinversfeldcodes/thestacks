defmodule StacksWeb.MetricsController do
  @moduledoc """
  Authenticated controller for the admin metrics dashboard.

  Only accessible to users with `role: "owner"`. Returns aggregated
  platform metrics from dbt marts with graceful fallback.
  """

  use CoreWeb, :controller

  alias Stacks.Admin.Metrics

  @doc """
  GET /api/metrics — returns the full metrics dashboard.

  Requires authentication and owner role.
  """
  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case user do
      %{role: "owner"} ->
        dashboard = Metrics.dashboard()
        json(conn, %{data: dashboard})

      _ ->
        conn
        |> put_status(403)
        |> json(%{error: "Forbidden — owner role required"})
    end
  end

  @doc """
  GET /api/metrics/quality-trends — returns quality trend sparkline data.

  Requires authentication and owner role.
  """
  def quality_trends(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case user do
      %{role: "owner"} ->
        trends = Metrics.quality_trends()
        json(conn, %{data: trends})

      _ ->
        conn
        |> put_status(403)
        |> json(%{error: "Forbidden — owner role required"})
    end
  end

  @doc """
  GET /api/metrics/source-health — returns per-source health status.

  Requires authentication and owner role.
  """
  def source_health(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case user do
      %{role: "owner"} ->
        health = Metrics.source_health()
        json(conn, %{data: health})

      _ ->
        conn
        |> put_status(403)
        |> json(%{error: "Forbidden — owner role required"})
    end
  end

  @doc """
  GET /api/metrics/enrichment-gaps — returns enrichment gap counts.

  Requires authentication and owner role.
  """
  def enrichment_gaps(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case user do
      %{role: "owner"} ->
        gaps = Metrics.enrichment_gaps()
        json(conn, %{data: gaps})

      _ ->
        conn
        |> put_status(403)
        |> json(%{error: "Forbidden — owner role required"})
    end
  end
end
