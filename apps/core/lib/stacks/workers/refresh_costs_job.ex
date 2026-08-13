defmodule Stacks.Workers.RefreshCostsJob do
  @moduledoc """
      Daily Oban worker that refreshes platform cost data.

      Prefers measured figures over estimates: the core app's own awake time
      from its pushed metrics, and the whole-account Fly/Neon month-to-date
      gauges a scheduled workflow computes from provider billing inputs and
      pushes into VictoriaMetrics. Each measurement falls back independently
      to a flat rate-card estimate when unavailable. Modal inference stays
      estimated from the vision-job count (Modal exposes no billing API).

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

    vision_jobs = Costs.vision_jobs_this_month()

    core_awake_seconds =
      case Costs.core_awake_seconds(period_start, now) do
        {:ok, seconds} -> seconds
        :error -> nil
      end

    fly_services_cents = billing_gauge("fly")
    neon_cents = billing_gauge("neon")

    cost_items =
      Costs.build_cost_items(period_start, period_end, vision_jobs,
        core_awake_seconds: core_awake_seconds,
        fly_services_cents: fly_services_cents,
        neon_cents: neon_cents,
        together_completions: metric_count("stacks_ai_together_completion_count_total"),
        brave_searches: metric_count("stacks_discovery_brave_search_count_total"),
        isbn_lookups: metric_count("stacks_moderation_isbn_resolution_count_total"),
        emails_sent: Costs.emails_this_month()
      )

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

  defp billing_gauge(provider) do
    case Costs.billing_gauge_cents(provider) do
      {:ok, cents} -> cents
      :error -> nil
    end
  end

  defp metric_count(family) do
    case Costs.metric_count_this_month(family) do
      {:ok, count} -> count
      :error -> nil
    end
  end

  defp beginning_of_month(%DateTime{} = dt) do
    %{dt | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp end_of_month(%DateTime{} = dt) do
    days = Calendar.ISO.days_in_month(dt.year, dt.month)
    %{dt | day: days, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
  end
end
