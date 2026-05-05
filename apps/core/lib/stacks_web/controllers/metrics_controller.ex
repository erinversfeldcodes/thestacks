defmodule StacksWeb.MetricsController do
  @moduledoc """
  Authenticated controller for the admin metrics dashboard.

  Requires an MFA-verified admin session JWT. Role is enforced at JWT issuance
  by `AdminAuthController.login/2` — not repeated per action.
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
