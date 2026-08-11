defmodule Stacks.Events.Upcaster do
  @moduledoc """
  Migrates events from older `schema_version`s forward. To add an upcast:
  match `%{event_type: ..., schema_version: old}`, transform the payload,
  bump the version. Unknown versions pass through unchanged (forward
  compatibility). Every `PayloadContract` entry with `version > 1` must
  have a clause here — enforced by test.
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
