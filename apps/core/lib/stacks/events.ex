defmodule Stacks.Events do
  @moduledoc """
  Event emission module. Inserts events into the `op.event_log` table.
  The event_log is append-only — records are never updated or deleted (except
  GDPR erasure, which zeroes out payloads for deleted-user events).
  """

  require Logger

  alias Core.Repo

  @doc """
  Emits an event by inserting a record into the event_log table.

  Accepts a map with the following keys:
  - `:event_type` (required) — e.g. "user.registered", "book.created"
  - `:aggregate_type` (required) — e.g. "user", "book"
  - `:aggregate_id` (required) — UUID of the aggregate
  - `:payload` (optional) — map of event data (stored as jsonb)
  - `:metadata` (optional) — map of metadata (stored as jsonb)

  Returns `{:error, :emit_failed}` if the row was not inserted.
  """
  @spec emit(map()) :: {:ok, map()} | {:error, term()}
  def emit(%{event_type: _, aggregate_type: _, aggregate_id: _} = event) do
    now = DateTime.utc_now()

    params = %{
      id: Ecto.UUID.dump!(Ecto.UUID.generate()),
      event_type: event.event_type,
      aggregate_type: event.aggregate_type,
      aggregate_id: encode_uuid(to_string(event.aggregate_id)),
      payload: Map.get(event, :payload, %{}),
      metadata: Map.get(event, :metadata, %{}),
      occurred_at: now
    }

    case Repo.insert_all("event_log", [params], prefix: "op") do
      {1, _} -> {:ok, params}
      {0, _} -> {:error, :emit_failed}
    end
  rescue
    error -> {:error, error}
  end

  defp encode_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, binary} -> binary
      :error -> nil
    end
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
end
