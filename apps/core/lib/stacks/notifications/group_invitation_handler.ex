defmodule Stacks.Notifications.GroupInvitationHandler do
  @moduledoc """
      Event handler that enqueues a group invitation email when a user is invited
      to a group.

      Implements `Stacks.Events.Handler` and is registered in
      `Stacks.Events.Registry` for the `"group.invitation_sent"` event type.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Accounts
  alias Stacks.Workers.EmailDeliveryJob

  @impl true
  @spec handle_event(map()) :: :ok | {:error, term()}
  # ⚠️ These keys are the ones the emitter ACTUALLY sets. They were not.
  #
  # `Social.invite_to_group/3` emits `%{invited_user_id:, invited_by_id:,
  # invitation_id:}` with `aggregate_id: group_id`. This handler read
  # `invitee_id`, `inviter_name`, `group_name` and `invitation_id` — of which
  # only the last now exists. So `invitee_id` was always `nil`,
  # `Accounts.get_user(nil)` always returned `nil`, and every invitation logged
  # "invitee not found" and sent nothing. The group-invitation email has never
  # been delivered.
  #
  # The two NAMES were never going to arrive: `event_log` payloads are
  # UUID-only by contract, so a handler cannot read a display name out of one.
  # They are resolved at delivery from the ids instead.
  def handle_event(%{
        event_type: "group.invitation_sent",
        aggregate_id: group_id,
        payload: payload
      }) do
    invitee_id = Map.get(payload, "invited_user_id") || Map.get(payload, :invited_user_id)
    inviter_id = Map.get(payload, "invited_by_id") || Map.get(payload, :invited_by_id)
    invitation_id = Map.get(payload, "invitation_id") || Map.get(payload, :invitation_id)

    case Accounts.get_user(invitee_id) do
      nil ->
        Logger.warning("GroupInvitationHandler: invitee #{invitee_id} not found, skipping")
        :ok

      user ->
        if user.notify_group_invitations do
          enqueue_email(user.id, inviter_id, group_id, invitation_id)
        else
          :ok
        end
    end
  end

  def handle_event(_event), do: :ok

  # ⚠️ Ids only. `inviter_name` is a THIRD PARTY's name — the job's `user_id`
  # is the invitee, the inviter is someone else — and `oban_jobs.args` is a
  # queryable table with no erasure path that now retains rows for seven days.
  # A scrub keyed on `args->>'user_id'` could never reach a name belonging to a
  # different person, so the only safe shape is not to put it there.
  defp enqueue_email(user_id, inviter_id, group_id, invitation_id) do
    args = %{
      "template" => "group_invitation",
      "user_id" => user_id,
      "params" => %{
        "inviter_id" => inviter_id,
        "group_id" => group_id,
        "invitation_id" => invitation_id
      }
    }

    case EmailDeliveryJob.new(args) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("GroupInvitationHandler: failed to enqueue: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
