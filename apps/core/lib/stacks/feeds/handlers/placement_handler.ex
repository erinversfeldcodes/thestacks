defmodule Stacks.Feeds.Handlers.PlacementHandler do
  @moduledoc """
  Event handler that enqueues feed regeneration when shelf placements change.

  Listens for `placement.created`, `placement.moved`, `placement.removed` and
  `placement.restored` events and enqueues a `RegenerateFeedJob` for the
  affected bookshelf.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  import Ecto.Query

  alias Stacks.Shelving.Bookshelf
  alias Stacks.Shelving.Placement
  alias Stacks.Workers.RegenerateFeedJob

  @placement_events ~w(placement.created placement.moved placement.removed placement.restored)

  @impl true
  def handle_event(%{event_type: event_type, aggregate_id: aggregate_id, payload: payload})
      when event_type in @placement_events do
    if import_sourced?(event_type, payload) do
      # A Goodreads import creates hundreds of placements in minutes; one
      # RegenerateFeedJob per placement is O(n²) feed rebuilds. The import job
      # enqueues ONE regeneration per touched bookshelf at finalize
      # (Stacks.Imports.finalize/2), so this handler stands down for those
      # events rather than duplicating the work n times.
      :ok
    else
      regenerate_for(event_type, aggregate_id, payload)
    end
  end

  # Catch-all clause — ignore unrecognized events
  def handle_event(_event), do: :ok

  defp import_sourced?("placement.created", payload) do
    (Map.get(payload, "source") || Map.get(payload, :source)) == "goodreads_import"
  end

  defp import_sourced?(_event_type, _payload), do: false

  defp regenerate_for(event_type, aggregate_id, payload) do
    bookshelf_name = extract_bookshelf_name(event_type, payload)

    # For moved events, regenerate both source and destination feeds
    bookshelf_names =
      case event_type do
        "placement.moved" ->
          from = Map.get(payload, "from_bookshelf") || Map.get(payload, :from_bookshelf)
          [bookshelf_name, from] |> Enum.reject(&is_nil/1) |> Enum.uniq()

        _ ->
          [bookshelf_name] |> Enum.reject(&is_nil/1)
      end

    user_id = lookup_user_id(aggregate_id)

    if user_id do
      Enum.each(bookshelf_names, &enqueue_feed_regeneration(user_id, &1))
    end

    :ok
  end

  defp enqueue_feed_regeneration(_user_id, nil), do: :ok

  defp enqueue_feed_regeneration(user_id, bookshelf_name) do
    case %{user_id: user_id, bookshelf_name: bookshelf_name}
         |> RegenerateFeedJob.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "PlacementHandler: failed to enqueue feed regeneration: #{inspect(reason)}"
        )
    end
  end

  defp extract_bookshelf_name("placement.created", payload) do
    Map.get(payload, "bookshelf") || Map.get(payload, :bookshelf)
  end

  defp extract_bookshelf_name("placement.moved", payload) do
    Map.get(payload, "to_bookshelf") || Map.get(payload, :to_bookshelf)
  end

  # A removal carries no bookshelf name and needs none: whichever feed the book
  # was in loses it, and `lookup_user_id/1` plus a full regeneration covers that.
  defp extract_bookshelf_name("placement.removed", _payload), do: nil

  # An undo does need one. The book is going back into a specific bookshelf's
  # feed, and the payload names it (see PayloadContract).
  defp extract_bookshelf_name("placement.restored", payload) do
    Map.get(payload, "bookshelf") || Map.get(payload, :bookshelf)
  end

  defp extract_bookshelf_name(_, _), do: nil

  defp lookup_user_id(placement_id) do
    query =
      from(bp in Placement,
        join: bs in Bookshelf,
        on: bs.id == bp.bookshelf_id,
        where: bp.id == type(^placement_id, Ecto.UUID),
        select: type(bs.user_id, Ecto.UUID)
      )

    Core.Repo.one(query)
  rescue
    _ -> nil
  end
end
