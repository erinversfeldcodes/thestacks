defmodule StacksWeb.MetricsController do
  @moduledoc """
  Authenticated controller for the admin metrics dashboard.

  Only accessible to users with `role: "owner"`. The role check is enforced
  by the `RequireRole` plug in the router pipeline — not repeated per action.
  """

  use CoreWeb, :controller

  alias Stacks.Admin.Metrics

  @doc "GET /api/metrics — returns the full metrics dashboard."
  def index(conn, _params) do
    json(conn, %{data: Metrics.dashboard()})
  end

  @doc "GET /api/metrics/quality-trends — returns quality trend sparkline data."
  def quality_trends(conn, _params) do
    json(conn, %{data: Metrics.quality_trends()})
  end

  @doc "GET /api/metrics/source-health — returns per-source health status."
  def source_health(conn, _params) do
    json(conn, %{data: Metrics.source_health()})
  end

  @doc "GET /api/metrics/enrichment-gaps — returns enrichment gap counts."
  def enrichment_gaps(conn, _params) do
    json(conn, %{data: Metrics.enrichment_gaps()})
  end
end
