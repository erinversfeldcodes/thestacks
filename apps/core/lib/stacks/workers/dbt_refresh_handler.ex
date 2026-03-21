defmodule Stacks.Workers.DbtRefreshHandler do
  @moduledoc false

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Workers.DbtRefreshJob

  @model_mapping %{
    "enrichment.prices_scraped" => ["int_price_trends", "mart_book_prices"],
    "enrichment.reviews_scraped" => ["int_review_sentiment", "mart_book_reviews"],
    "enrichment.author_updated" => ["int_author_activity"],
    "enrichment.events_discovered" => ["int_event_matches"],
    "source_health.recorded" => ["mart_system_health"],
    "placement.created" => ["mart_community_read_count", "mart_platform_searchable"],
    "placement.moved" => ["mart_community_read_count"]
  }

  @impl true
  def handle_event(%{event_type: event_type}) do
    case Map.get(@model_mapping, event_type) do
      nil ->
        :ok

      models ->
        case %{models: models}
             |> DbtRefreshJob.new()
             |> Oban.insert() do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning("DbtRefreshHandler: failed to enqueue dbt refresh: #{inspect(reason)}")

            {:error, reason}
        end
    end
  end

  def handle_event(_event), do: :ok
end
