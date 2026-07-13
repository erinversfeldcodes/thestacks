defmodule Stacks.Events do
  @moduledoc """
  Event emission module. Inserts events into the `op.event_log` table and
  dispatches them to registered handlers via `Stacks.Events.SubscriberWorker`.

  The event_log is append-only — records are never deleted, including during
  GDPR erasure. For `user` aggregates the going-forward contract is that
  payloads are UUID-only (no PII): consumers read the current state from the
  user record via `aggregate_id`. As a defence-in-depth safety net for any
  legacy rows that predate that contract, GDPR erasure (`Stacks.GDPR.Deletion`)
  redacts the erased user's own rows in place — emptying `payload` and
  `metadata` to `{}` — rather than deleting them, preserving the event stream
  while scrubbing PII (matches the CLAUDE.md invariant: "immutable, except GDPR
  erasure of PII in payloads").
  """

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Events.EventLog
  alias Stacks.Events.SubscriberWorker
  alias Stacks.Events.Upcaster

  @replay_batch_size 500

  @doc """
  Emits an event by inserting a record into the event_log table and enqueuing
  a `SubscriberWorker` job to dispatch the event to registered handlers.

  Accepts a map with the following keys:
  - `:event_type` (required) — e.g. "user.registered", "book.created"
  - `:aggregate_type` (required) — e.g. "user", "book"
  - `:aggregate_id` (required) — UUID of the aggregate
  - `:payload` (optional) — map of event data (stored as jsonb)
  - `:metadata` (optional) — map of metadata (stored as jsonb)
  - `:schema_version` (optional) — integer schema version (defaults to 1)

  Returns `{:error, :emit_failed}` if the row was not inserted.
  The Oban enqueue is best-effort: if it fails, the event is still persisted
  and a warning is logged.

  See `proto/stacks/internal/v1/event_bus.proto` (`EventEnvelope`) for the
  canonical field contract.
  """
  @spec emit(%{
          required(:event_type) => String.t(),
          required(:aggregate_type) => String.t(),
          required(:aggregate_id) => String.t() | Ecto.UUID.t(),
          optional(:schema_version) => pos_integer(),
          optional(:payload) => map(),
          optional(:metadata) => map()
        }) :: {:ok, map()} | {:error, term()}
  def emit(%{event_type: _, aggregate_type: _, aggregate_id: _} = event) do
    now = DateTime.utc_now()
    event_id = Ecto.UUID.generate()

    params = %{
      id: event_id,
      event_type: event.event_type,
      aggregate_type: event.aggregate_type,
      aggregate_id: to_string(event.aggregate_id),
      payload: Map.get(event, :payload, %{}),
      metadata: Map.get(event, :metadata, %{}),
      schema_version: Map.get(event, :schema_version, 1),
      occurred_at: now
    }

    case Repo.insert_all(EventLog, [params]) do
      {1, _} ->
        # Throughput signal. Tagged by event_type so we can see which
        # flows are noisy (e.g. `book.created` vs `placement.moved`)
        # and size the :events Oban queue accordingly. Aggregated by
        # PromEx into `stacks_events_emitted_count_total` — see
        # Core.PromEx.Plugins.Stacks. The event name here MUST match
        # the `event_name:` key on the Counter definition in the
        # PromEx plugin (not the metric name — that has the
        # `:count, :total` suffix appended by Telemetry.Metrics).
        :telemetry.execute(
          [:stacks, :events, :emitted],
          %{count: 1},
          %{event_type: event.event_type, aggregate_type: event.aggregate_type}
        )

        enqueue_subscriber(event_id)
        {:ok, params}

      {0, _} ->
        {:error, :emit_failed}
    end
  rescue
    error -> {:error, error}
  end

  defp enqueue_subscriber(event_id) do
    case Oban.insert(SubscriberWorker.new(%{event_id: event_id})) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to enqueue SubscriberWorker for event #{event_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to enqueue SubscriberWorker for event #{event_id}: #{inspect(exception)}"
      )

      :ok
  end

  @doc """
  Emits an event with best-effort semantics. Logs a warning on failure but
  always returns `{:ok, event_params}` so callers (e.g. `Ecto.Multi` steps)
  are not rolled back due to event infrastructure failures.
  """
  @spec emit_safe(map()) :: {:ok, map()}
  def emit_safe(event) do
    case emit(event) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "Event emission failed for #{inspect(Map.get(event, :event_type))}: #{inspect(reason)}"
        )

        {:ok, event}
    end
  end

  @doc """
  Replays historical events of the given type to a single handler module.

  Fetches events from `op.event_log` matching `event_type` and occurring at or
  after `from_datetime`, applies `Stacks.Events.Upcaster.upcast/1` to each,
  and dispatches to `handler_module.handle_event/1`.

  Events are processed in batches of #{@replay_batch_size} to prevent memory
  blowout on large event logs.

  ## Use cases
  - Backfilling a newly registered handler
  - Recovering from handler failures
  - Audit replay

  Returns `{:ok, count}` where `count` is the total number of events replayed.
  """
  @spec replay(String.t(), DateTime.t(), module()) :: {:ok, non_neg_integer()}
  def replay(event_type, %DateTime{} = from_datetime, handler_module)
      when is_binary(event_type) and is_atom(handler_module) do
    count = do_replay(event_type, from_datetime, handler_module, 0, 0)
    {:ok, count}
  end

  defp do_replay(event_type, from_datetime, handler_module, offset, acc) do
    events = fetch_batch(event_type, from_datetime, offset)

    case events do
      [] ->
        acc

      batch ->
        Enum.each(batch, fn event ->
          event
          |> Upcaster.upcast()
          |> handler_module.handle_event()
        end)

        do_replay(
          event_type,
          from_datetime,
          handler_module,
          offset + length(batch),
          acc + length(batch)
        )
    end
  end

  defp fetch_batch(event_type, from_datetime, offset) do
    from(e in EventLog,
      where: e.event_type == ^event_type,
      where: e.occurred_at >= ^from_datetime,
      order_by: [asc: e.occurred_at, asc: e.id],
      offset: ^offset,
      limit: ^@replay_batch_size,
      select: %{
        id: e.id,
        event_type: e.event_type,
        aggregate_type: e.aggregate_type,
        aggregate_id: e.aggregate_id,
        schema_version: e.schema_version,
        payload: e.payload,
        metadata: e.metadata,
        occurred_at: e.occurred_at,
        published_at: e.published_at
      }
    )
    |> Repo.all()
  end
end
