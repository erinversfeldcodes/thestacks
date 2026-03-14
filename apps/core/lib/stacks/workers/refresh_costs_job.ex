defmodule Stacks.Workers.RefreshCostsJob do
  @moduledoc """
  Daily Oban worker that refreshes platform cost data.

  Inserts or updates cost line items in `op.platform_costs` for the current
  billing period. In production, this would pull from billing APIs (Fly.io,
  Modal, Neon, domain registrar). Currently uses static placeholder values
  that represent the actual expected costs.

  The worker emits a `costs.refreshed` event on success.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Costs
  alias Stacks.Events

  @impl true
  def perform(_job) do
    Logger.info("RefreshCostsJob: refreshing platform cost data")

    now = DateTime.utc_now()
    period_start = beginning_of_month(now)
    period_end = end_of_month(now)

    cost_items = build_cost_items(period_start, period_end)

    results =
      Enum.map(cost_items, fn item ->
        case Costs.upsert_cost(item) do
          {:ok, cost} ->
            {:ok, cost}

          {:error, changeset} ->
            Logger.error(
              "RefreshCostsJob: failed to upsert #{item.service}: #{inspect(changeset.errors)}"
            )

            {:error, item.service}
        end
      end)

    failures = Enum.filter(results, &match?({:error, _}, &1))

    if failures == [] do
      Events.emit_safe(%{
        event_type: "costs.refreshed",
        aggregate_type: "platform",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{item_count: length(cost_items), period: DateTime.to_iso8601(period_start)},
        metadata: %{actor: "system:refresh_costs_job"}
      })

      Logger.info("RefreshCostsJob: refreshed #{length(cost_items)} cost items")
      :ok
    else
      Logger.error("RefreshCostsJob: #{length(failures)} items failed")
      {:error, "#{length(failures)} cost items failed to upsert"}
    end
  end

  defp build_cost_items(period_start, period_end) do
    base = %{period_start: period_start, period_end: period_end, currency: "USD"}

    [
      Map.merge(base, %{
        category: "hosting",
        service: "Fly.io Core",
        description: "Phoenix API server (shared-cpu-1x, 256MB)",
        amount_cents: 534
      }),
      Map.merge(base, %{
        category: "hosting",
        service: "Fly.io Vision",
        description: "Vision sidecar (shared-cpu-1x, 256MB)",
        amount_cents: 534
      }),
      Map.merge(base, %{
        category: "compute",
        service: "Modal Vision API",
        description: "Together AI vision model inference",
        amount_cents: 200
      }),
      Map.merge(base, %{
        category: "database",
        service: "Neon PostgreSQL",
        description: "Serverless PostgreSQL (free tier)",
        amount_cents: 0
      }),
      Map.merge(base, %{
        category: "domain",
        service: "Domain Registration",
        description: "Annual domain registration (amortised monthly)",
        amount_cents: 100
      })
    ]
  end

  defp beginning_of_month(%DateTime{} = dt) do
    %{dt | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp end_of_month(%DateTime{} = dt) do
    days = Calendar.ISO.days_in_month(dt.year, dt.month)
    %{dt | day: days, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
  end
end
