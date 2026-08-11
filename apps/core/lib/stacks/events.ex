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
  alias Stacks.Events.PayloadContract
  alias Stacks.Events.SubscriberWorker
  alias Stacks.Events.Upcaster

  @replay_batch_size 500

  @doc """
    Emits an event: inserts into `event_log` and enqueues a
    `SubscriberWorker` to dispatch to registered handlers. Required keys:
    `:event_type`, `:aggregate_type`, `:aggregate_id`; optional `:payload`,
    `:metadata`, `:schema_version` (default 1). Canonical field contract:
    `EventEnvelope` in `proto/stacks/internal/v1/event_bus.proto`.
    `{:error,:emit_failed}` if the insert failed; the Oban enqueue is
    best-effort (event persists, warning logged).
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
    if Application.get_env(:core, :validate_event_payload_contract, false),
      do: PayloadContract.validate!(event)

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
    e in PayloadContract.Violation -> reraise e, __STACKTRACE__
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
    Replays historical events of a type to one handler: fetches
    `op.event_log` rows at/after `from_datetime`, upcasts each
    (`Upcaster.upcast/1`), dispatches to `handler_module.handle_event/1` in
    batches of #{@replay_batch_size}. For backfilling new handlers, recovery,
    and audit replay. Returns `{:ok, count}`.
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
