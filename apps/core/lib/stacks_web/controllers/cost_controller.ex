defmodule StacksWeb.CostController do
  @moduledoc """
      Public controller for platform cost transparency data.

      Serves aggregate infrastructure costs without authentication.
      No user data is exposed — only platform operational costs.
  """

  use CoreWeb, :controller

  alias Stacks.Costs

  @doc """
      GET /api/costs — returns the full cost breakdown for the current period.

      Response includes line items, total, cost-per-book, and monthly history.
  """
  def index(conn, _params) do
    breakdown = Costs.cost_breakdown()
    json(conn, %{data: breakdown})
  end
end
