defmodule Stacks.Events.Upcaster do
  @moduledoc """
      Migrates events from older `schema_version`s forward. To add an upcast:
      match `%{event_type:..., schema_version: old}`, transform the payload,
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

  # v1 invitation events predate `invitation_id`. There is no way to recover it
  # — the invitation row may be gone, and guessing one would build an accept
  # link to the wrong invitation — so the key is simply absent and the handler
  # must tolerate that. It does: a nil `invitation_id` yields a dead accept
  # link, which is the honest outcome for an invitation whose id was never
  # recorded, and is no worse than the v1 behaviour where no email was sent
  # at all.
  def upcast(%{event_type: "group.invitation_sent", schema_version: 1} = event),
    do: %{event | schema_version: 2}

  # v1 reverts predate `initiated_by` and there is no way to recover it: the
  # audit log records operator restores, but a v1 event carries no link to an
  # audit row and matching on timestamps would invent attribution. So the key
  # is absent and a consumer must tolerate that — which is the honest outcome
  # for an event that genuinely did not record who acted, and no worse than v1,
  # where the distinction did not exist at all.
  def upcast(%{event_type: "user.email_change_reverted", schema_version: 1} = event),
    do: %{event | schema_version: 2}

  def upcast(%{schema_version: 1} = event), do: event

  def upcast(event), do: event

  defp drop_blog_title(%{payload: payload} = event),
    do: %{event | payload: Map.drop(payload, ["title", :title]), schema_version: 2}

  defp drop_blog_title(event), do: %{event | schema_version: 2}
end
