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

  # Events this handler is SUBSCRIBED to on purpose while having no models to
  # refresh, each with the reason. Without this, "subscribed but unmapped" and
  # "someone forgot the mapping" are the same silent no-op.
  #
  # ⚠️ This is the inverse of the gate on @model_mapping, and it is the direction
  # that bites later rather than now: a mapping naming a deleted model fails a
  # set difference against the models on disk, but an event with NO key at all
  # matches nothing, enqueues nothing, logs nothing, and returns :ok. The
  # registry calls this handler "subscribed" for the review rebuild — true, and
  # worth nothing on the day the emitter returns unless somebody also restores
  # the mapping. Hence: declared here, and checked by
  # `scripts/check-dbt-model-drift.sh`, which fails on any subscribed event that
  # is neither mapped nor named below.
  #
  # ⚠️ Why a GATE and not a `CompileError` like the registry's own guard. Not
  # because this is runtime data — `@model_mapping` is a compile-time literal and
  # a CompileError over it is technically available. The reason is that this
  # invariant SPANS TWO MODULES: it is
  # `Registry.@registry − @model_mapping − @subscribed_without_models`, so
  # enforcing it at compile time would make this module read the registry during
  # compilation, buying a compile-time dependency and a recompile cascade — touch
  # the registry, rebuild every handler — in a repo that already pays real costs
  # for toolchain-level mystery. The registry's guard is cheap precisely because
  # it compares three literals in its OWN module and depends on nothing outside.
  # The gate is also strictly stronger than a CompileError here: static analysis
  # pre-merge, with no coupling. The runtime warning below is defence in depth
  # for what static analysis cannot see — a registry edited where the gate did
  # not run, or an event_type that appears in no static list at all.
  #
  # Division of labour with the registry, so neither record restates the other:
  # the registry carries WHY THE SUBSCRIPTION EXISTS (the ruling, the policy, the
  # rebuild); this map carries WHY IT MAPS NOTHING. Keep the reason below short
  # and pointed at the mapping question — if it starts reciting the owner ruling,
  # the two have begun to drift.
  @subscribed_without_models %{
    "enrichment.reviews_scraped" =>
      "the review vertical returns by owner ruling and this subscription is kept so " <>
        "the rebuild lands with its consumer already attached — but its three dbt " <>
        "models were deleted, so there is nothing to refresh until the rebuild " <>
        "recreates them. Restore the mapping in the same change that recreates the " <>
        "models, or this handler will run and refresh nothing while reporting success."
  }

  @doc false
  def subscribed_without_models, do: @subscribed_without_models

  @impl true
  def handle_event(%{event_type: event_type}) do
    case Map.get(@model_mapping, event_type) do
      nil ->
        warn_if_undeclared(event_type)
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

  # A declared keyless event is silent; anything else reaching here means this
  # handler was subscribed to something it cannot act on, which is the shape the
  # registry's completeness test exists to surface and is worth saying out loud
  # at runtime too.
  defp warn_if_undeclared(event_type) do
    unless Map.has_key?(@subscribed_without_models, event_type) do
      Logger.warning(
        "DbtRefreshHandler: subscribed to #{event_type} with no models mapped and no declared " <>
          "exception, so this refreshed nothing. THIS LINE SHOULD BE UNREACHABLE: " <>
          "scripts/check-dbt-model-drift.sh asserts the condition cannot exist, so reaching here " <>
          "means the gate was bypassed or the registry changed without it running. Either map " <>
          "this event's models, unsubscribe the handler, or declare the gap."
      )
    end

    :ok
  end
end
