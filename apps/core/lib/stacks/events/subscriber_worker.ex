defmodule Stacks.Events.SubscriberWorker do
  @moduledoc """
  Oban worker that dispatches a persisted event to all registered handlers.

  Enqueued by `Stacks.Events.emit/1` after writing to `op.event_log`. The job
  args contain only `%{"event_id" => uuid}` — the full event is fetched from
  the database at execution time. This avoids storing PII in the Oban jobs
  table.

  Each handler call is isolated with `try/rescue` so that one failing handler
  does not prevent other handlers from receiving the event.
  """

  use Oban.Worker, queue: :events, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Events.Registry
  alias Stacks.Events.Upcaster

  @impl true
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    case fetch_event(event_id) do
      {:ok, event} ->
        event = Upcaster.upcast(event)
        dispatch(event)
        mark_published(event.id)
        :ok

      {:error, :not_found} ->
        Logger.error("SubscriberWorker: event #{event_id} not found in event_log")
        {:cancel, "event not found"}
    end
  end

  defp fetch_event(event_id) do
    {:ok, event_id_bin} = Ecto.UUID.dump(event_id)

    query =
      from(e in "event_log",
        where: e.id == ^event_id_bin,
        select: %{
          id: e.id,
          event_type: e.event_type,
          aggregate_type: e.aggregate_type,
          aggregate_id: e.aggregate_id,
          schema_version: e.schema_version,
          payload: e.payload,
          metadata: e.metadata,
          occurred_at: e.occurred_at
        }
      )

    case Repo.one(query, prefix: "op") do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  defp mark_published(id_bin) do
    Repo.update_all(
      from(e in "event_log", where: e.id == ^id_bin),
      [set: [published_at: DateTime.utc_now()]],
      prefix: "op"
    )
  end

  defp dispatch(event) do
    handlers = Registry.handlers_for(event.event_type)

    Enum.each(handlers, fn handler ->
      try do
        case handler.handle_event(event) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "SubscriberWorker: handler #{inspect(handler)} returned error " <>
                "for event #{event.event_type}: #{inspect(reason)}"
            )

            :telemetry.execute(
              [:stacks, :events, :handler_error],
              %{count: 1},
              %{handler: inspect(handler), event_type: event.event_type}
            )
        end
      rescue
        exception ->
          Logger.error(
            "SubscriberWorker: handler #{inspect(handler)} raised for event " <>
              "#{event.event_type}: #{Exception.format(:error, exception, __STACKTRACE__)}"
          )

          :telemetry.execute(
            [:stacks, :events, :handler_error],
            %{count: 1},
            %{handler: inspect(handler), event_type: event.event_type}
          )
      end
    end)
  end
end
