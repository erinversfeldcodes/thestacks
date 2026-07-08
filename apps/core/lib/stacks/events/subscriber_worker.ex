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
  alias Stacks.Events.EventLog
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
    query =
      from(e in EventLog,
        where: e.id == ^event_id,
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

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  defp mark_published(id_bin) do
    Repo.update_all(
      from(e in EventLog, where: e.id == ^id_bin),
      set: [published_at: DateTime.utc_now()]
    )
  end

  defp dispatch(event) do
    handlers = Registry.handlers_for(event.event_type)

    Enum.each(handlers, fn handler ->
      invoke_handler_with_telemetry(handler, event)
    end)
  end

  # Wrap each handler call in a stopwatch + telemetry emission so
  # operators can identify slow or broken handlers by event_type.
  # Distinct events:
  #   - `:dispatch.duration` (distribution): wall-clock ms spent in
  #     `handler.handle_event/1`. Tagged by handler module + event_type.
  #     Answers "which handlers are holding Oban worker slots longest?"
  #   - `:handler_invoked.count.total` (counter): every invocation,
  #     regardless of outcome. Answers "which handlers fire most
  #     often?" — divides execution time fairly across traffic shape.
  #   - `:handler_error.count.total` (counter): retains the existing
  #     error-rate signal, just renamed to fit the PromEx
  #     `[...].count.total` convention so the exported metric ends in
  #     `_total` cleanly.
  defp invoke_handler_with_telemetry(handler, event) do
    start = System.monotonic_time()
    tags = %{handler: inspect(handler), event_type: event.event_type}

    # Event path matches the `event_name:` key on the PromEx
    # Counter — NOT the full metric path. Telemetry.Metrics appends
    # `:count, :total` to form the Prometheus name; callers emit on
    # the shorter event path.
    :telemetry.execute(
      [:stacks, :events, :handler_invoked],
      %{count: 1},
      tags
    )

    try do
      case handler.handle_event(event) do
        :ok ->
          emit_dispatch_duration(start, tags)
          :ok

        {:error, reason} ->
          emit_dispatch_duration(start, tags)

          Logger.error(
            "SubscriberWorker: handler #{inspect(handler)} returned error " <>
              "for event #{event.event_type}: #{inspect(reason)}"
          )

          :telemetry.execute(
            [:stacks, :events, :handler_error],
            %{count: 1},
            tags
          )
      end
    rescue
      exception ->
        emit_dispatch_duration(start, tags)

        Logger.error(
          "SubscriberWorker: handler #{inspect(handler)} raised for event " <>
            "#{event.event_type}: #{Exception.format(:error, exception, __STACKTRACE__)}"
        )

        :telemetry.execute(
          [:stacks, :events, :handler_error],
          %{count: 1},
          tags
        )
    end
  end

  defp emit_dispatch_duration(start, tags) do
    duration = System.monotonic_time() - start

    # `event_name:` on the PromEx distribution is
    # `[:stacks, :events, :dispatch]`; the unit suffix
    # `:duration, :milliseconds` is part of the METRIC name only.
    :telemetry.execute(
      [:stacks, :events, :dispatch],
      %{duration: duration},
      tags
    )
  end
end
