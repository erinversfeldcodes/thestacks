defmodule Stacks.Events.Upcaster do
  @moduledoc """
  Transforms events from older schema versions to the current version.

  Each event in `op.event_log` has a `schema_version` (integer, default 1).
  When the shape of an event's payload changes, add a new pattern-match clause
  here to migrate old payloads forward.

  ## Adding an upcast

  1. Add a clause matching `%{event_type: "the.type", schema_version: old_version}`.
  2. Transform the payload and bump `schema_version` to the new version.
  3. Document the migration reason in a comment above the clause.

  Unknown versions pass through unchanged (forward compatibility).
  """

  @doc """
  Upcasts an event map to the current schema version.

  Returns the event unchanged if it is already at the current version or if
  no upcast clause exists for the given type and version.
  """
  @spec upcast(map()) :: map()
  # Version 1 is the initial schema version for all event types.
  # No transformation needed — this clause documents that v1 is current.
  def upcast(%{schema_version: 1} = event), do: event

  # Catch-all: unknown versions pass through unchanged (forward compatibility).
  def upcast(event), do: event
end
