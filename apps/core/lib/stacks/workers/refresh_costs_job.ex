defmodule Stacks.Workers.RefreshCostsJob do
  @moduledoc """
  Daily Oban worker that refreshes platform cost data.

  Computes costs from known infrastructure pricing and actual usage metrics.
  Pricing is derived from published rate cards (Fly.io, Modal, Neon) and the
  actual VM specs in `deploy/fly.core.toml`. Usage-proportional costs (Modal
  inference) are estimated from the number of vision jobs this month.

  The worker emits a `costs.refreshed` event on success.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Costs
  alias Stacks.Events

  # ── Known pricing (from published rate cards) ─────────────────────────────
  # Fly.io shared-cpu-1x, 512MB: $5.34/mo (see fly.core.toml [[vm]])
  # Modal A10G GPU: ~$0.000463/sec (~$0.028/inference at ~60s)
  # Neon free tier: $0 (0.5 GiB storage, 190 compute hours)
  # Domain: ~$12/year = $1.00/month amortised

  @fly_core_cents 534
  @fly_vision_cents 534
  @modal_per_inference_cents 3
  @neon_cents 0
  @domain_monthly_cents 100

  @impl true
  def perform(_job) do
    Logger.info("RefreshCostsJob: refreshing platform cost data")

    now = DateTime.utc_now()
    period_start = beginning_of_month(now)
    period_end = end_of_month(now)

    vision_jobs = Costs.vision_jobs_this_month()
    cost_items = build_cost_items(period_start, period_end, vision_jobs)

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
        payload: %{
          item_count: length(cost_items),
          period: DateTime.to_iso8601(period_start),
          vision_jobs: vision_jobs
        },
        metadata: %{actor: "system:refresh_costs_job"}
      })

      Logger.info("RefreshCostsJob: refreshed #{length(cost_items)} cost items")
      :ok
    else
      Logger.error("RefreshCostsJob: #{length(failures)} items failed")
      {:error, "#{length(failures)} cost items failed to upsert"}
    end
  end

  defp build_cost_items(period_start, period_end, vision_jobs) do
    base = %{period_start: period_start, period_end: period_end, currency: "USD"}

    modal_cents = vision_jobs * @modal_per_inference_cents

    [
      Map.merge(base, %{
        category: "hosting",
        service: "Fly.io Core",
        description: "Phoenix API + Elm SPA (shared-cpu-1x, 512MB, IAD)",
        amount_cents: @fly_core_cents
      }),
      Map.merge(base, %{
        category: "hosting",
        service: "Fly.io Vision Sidecar",
        description: "FastAPI HMAC proxy to Modal (shared-cpu-1x, 512MB, IAD)",
        amount_cents: @fly_vision_cents
      }),
      Map.merge(base, %{
        category: "compute",
        service: "Modal GPU Inference",
        description: "Qwen2.5-VL-7B on A10G — #{vision_jobs} inferences this month (~$0.03/each)",
        amount_cents: modal_cents
      }),
      Map.merge(base, %{
        category: "database",
        service: "Neon PostgreSQL",
        description: "Serverless Postgres (free tier: 0.5 GiB, 190 compute hours)",
        amount_cents: @neon_cents
      }),
      Map.merge(base, %{
        category: "domain",
        service: "Domain Registration",
        description: "thestacks.app — annual registration amortised monthly",
        amount_cents: @domain_monthly_cents
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
