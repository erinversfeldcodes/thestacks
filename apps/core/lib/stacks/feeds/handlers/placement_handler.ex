defmodule Stacks.Feeds.Handlers.PlacementHandler do
  @moduledoc """
      Event handler that enqueues feed regeneration when shelf placements change.

      Listens for `placement.created`, `placement.moved`, `placement.removed` and
      `placement.restored` events and enqueues a `RegenerateFeedJob` for the
      affected bookshelf.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Workers.RegenerateFeedJob

  @placement_events ~w(placement.created placement.moved placement.removed placement.restored)

  @impl true
  def handle_event(%{event_type: event_type, aggregate_id: aggregate_id, payload: payload})
      when event_type in @placement_events do
    if import_sourced?(event_type, payload) do
      :ok
    else
      regenerate_for(event_type, aggregate_id, payload)
    end
  end

  def handle_event(_event), do: :ok

  defp import_sourced?("placement.created", payload) do
    (Map.get(payload, "source") || Map.get(payload, :source)) == "goodreads_import"
  end

  defp import_sourced?(_event_type, _payload), do: false

  defp regenerate_for(event_type, aggregate_id, payload) do
    bookshelf_name = extract_bookshelf_name(event_type, payload)

    bookshelf_names =
      case event_type do
        "placement.moved" ->
          from = Map.get(payload, "from_bookshelf") || Map.get(payload, :from_bookshelf)
          [bookshelf_name, from] |> Enum.reject(&is_nil/1) |> Enum.uniq()

        _ ->
          [bookshelf_name] |> Enum.reject(&is_nil/1)
      end

    case lookup_user_id(aggregate_id) do
      nil ->
        # ⚠️ A placement whose owner cannot be found is now REPORTED. It was
        # previously indistinguishable from a swallowed database refusal, and
        # the handler returned `:ok` either way.
        Logger.warning(
          "PlacementHandler: no owner found for placement #{inspect(aggregate_id)}; " <>
            "no feed regeneration enqueued for #{inspect(bookshelf_names)}"
        )

        :ok

      user_id ->
        Enum.each(bookshelf_names, &enqueue_feed_regeneration(user_id, &1))
        :ok
    end
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

  defp extract_bookshelf_name("placement.removed", _payload), do: nil

  defp extract_bookshelf_name("placement.restored", payload) do
    Map.get(payload, "bookshelf") || Map.get(payload, :bookshelf)
  end

  defp extract_bookshelf_name(_, _), do: nil

  # ⛔ Asks `op.placement_owner/1`, a narrow definer function, because this is
  # the one question per-user scoping cannot answer: the handler is an event
  # subscriber holding a placement id, and WHO the placement belongs to is
  # precisely what it is trying to find out. There is no user to scope to yet.
  #
  # ⛔ The previous version read the two secured tables directly under a
  # function-level `rescue _ -> nil`, and that combination was the worst failure
  # in this subsystem. The read was refused with `42501`, the rescue turned the
  # refusal into `nil`, the caller's `if user_id do` skipped the enqueue, and the
  # handler returned `:ok`. Feed regeneration failed completely and silently —
  # no 500, no log line, no Oban retry, nothing to notice. A bare rescue over a
  # database call cannot tell "this row does not exist" from "I was not allowed
  # to look", and those need opposite responses.
  defp lookup_user_id(placement_id) do
    case Core.Repo.query("SELECT op.placement_owner($1::uuid)", [
           Ecto.UUID.dump!(placement_id)
         ]) do
      {:ok, %{rows: [[owner]]}} when is_binary(owner) ->
        {:ok, uuid} = Ecto.UUID.load(owner)
        uuid

      {:ok, %{rows: [[nil]]}} ->
        nil

      {:error, reason} ->
        # ⚠️ Raised, not swallowed. An error here means the lookup mechanism is
        # broken rather than the placement being absent, and Oban retrying is
        # the correct response — the event is still in the log and the feed is
        # still stale.
        raise "PlacementHandler could not resolve the owner of placement " <>
                "#{inspect(placement_id)}: #{inspect(reason)}"
    end
  end
end
