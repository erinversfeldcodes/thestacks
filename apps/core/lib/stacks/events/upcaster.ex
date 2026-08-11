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
  def upcast(%{event_type: "blog.post_created", schema_version: 1} = event),
    do: drop_blog_title(event)

  def upcast(%{event_type: "blog.post_updated", schema_version: 1} = event),
    do: drop_blog_title(event)

  def upcast(%{event_type: "blog.post_published", schema_version: 1} = event),
    do: drop_blog_title(event)

  def upcast(%{schema_version: 1} = event), do: event

  def upcast(event), do: event

  defp drop_blog_title(%{payload: payload} = event),
    do: %{event | payload: Map.drop(payload, ["title", :title]), schema_version: 2}

  defp drop_blog_title(event), do: %{event | schema_version: 2}
end
