defmodule Stacks.Events do
  @moduledoc """
  Event emission module. Inserts events into the `op.event_log` table.
  The event_log is append-only — records are never updated or deleted (except
  GDPR-mandated PII scrubbing of payloads).
  """

  alias Core.Repo

  @doc """
  Emits an event by inserting a record into the event_log table.

  Accepts a map with the following keys:
  - `:event_type` (required) — e.g. "user.registered", "book.created"
  - `:aggregate_type` (required) — e.g. "user", "book"
  - `:aggregate_id` (required) — UUID of the aggregate
  - `:payload` (optional) — map of event data (stored as jsonb)
  - `:metadata` (optional) — map of metadata (stored as jsonb)
  """
  @spec emit(map()) :: {:ok, map()} | {:error, term()}
  def emit(%{event_type: _, aggregate_type: _, aggregate_id: _} = event) do
    now = DateTime.utc_now()

    params = %{
      id: Ecto.UUID.generate(),
      event_type: event.event_type,
      aggregate_type: event.aggregate_type,
      aggregate_id: to_string(event.aggregate_id),
      payload: Map.get(event, :payload, %{}),
      metadata: Map.get(event, :metadata, %{}),
      occurred_at: now
    }

    Repo.insert_all("event_log", [params], prefix: "op")
    {:ok, params}
  rescue
    error -> {:error, error}
  end
end
