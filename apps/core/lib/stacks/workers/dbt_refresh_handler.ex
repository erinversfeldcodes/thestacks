defmodule Stacks.Workers.DbtRefreshHandler do
  @moduledoc false

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Workers.DbtRefreshJob

  # ⚠️ Five event keys were removed from this map on 2026-10-15 because every model
  # they refreshed was deleted as an orphan — `mart_system_health`,
  # `int_blog_engagement`/`mart_blog_activity`, and
  # `int_review_sentiment`/`mart_book_reviews`.
  #
  # `handle_event/1` no-ops on an unmapped type, so leaving a key here with no
  # models would have been harmless and meaningless. What is NOT harmless is
  # leaving this handler SUBSCRIBED to an event it can no longer act on: that is
  # a handler which can never run, which is exactly what the registry's
  # completeness test exists to surface. So the subscriptions moved too, except
  # the one an owner ruling keeps — see the registry for each decision.
  @model_mapping %{
    "enrichment.prices_scraped" => ["int_price_trends", "mart_book_prices"],
    "enrichment.author_updated" => ["int_author_activity"],
    "enrichment.events_discovered" => ["int_event_matches"],
    "placement.created" => ["mart_community_read_count", "mart_platform_searchable"],
    "placement.moved" => ["mart_community_read_count"],
    # a removal (Shelving.remove_book/2 soft-deletes by
    # stamping removed_at) decrements a book's community read count.
    # mart_community_read_count is an INCREMENTAL table (not a view) whose body
    # filters `where removed_at is null`, so without a trigger the count stays
    # stale until the next scheduled dbt run. created/moved already refresh this
    # mart; removed changing the same numbers must too. The mart's incremental
    # predicate keys on updated_at, which remove_book's Multi.update bumps, so a
    # triggered run recomputes the affected book. Only mart_community_read_count
    # is mapped (mirroring moved): mart_platform_searchable derives from
    # int_book_detail_view, which does not reference placements, and books
    # survive removal — searchability is unaffected. Last-placement removal is
    # handled by the mart's tombstone semantics: the model
    # aggregates over ALL placements and counts active ones via a FILTER, so a
    # book whose LAST active placement is removed enters the incremental batch
    # (remove_book bumps updated_at) and recomputes to a read_count = 0 row,
    # which delete+insert uses to replace the stale non-zero row — drop-to-zero
    # no longer requires a --full-refresh.
    "placement.removed" => ["mart_community_read_count"],
    "placement.restored" => ["mart_community_read_count"]
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
