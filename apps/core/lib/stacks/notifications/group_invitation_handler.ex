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
  def handle_event(%{event_type: "group.invitation_sent", payload: payload}) do
    invitee_id = Map.get(payload, "invitee_id") || Map.get(payload, :invitee_id)
    inviter_name = Map.get(payload, "inviter_name") || Map.get(payload, :inviter_name, "A member")
    group_name = Map.get(payload, "group_name") || Map.get(payload, :group_name, "a group")
    invitation_id = Map.get(payload, "invitation_id") || Map.get(payload, :invitation_id)
    accept_url = "/groups/invitations/#{invitation_id}/accept"

    case Accounts.get_user(invitee_id) do
      nil ->
        Logger.warning("GroupInvitationHandler: invitee #{invitee_id} not found, skipping")
        :ok

      user ->
        if user.notify_group_invitations do
          enqueue_email(user.id, inviter_name, group_name, accept_url)
        else
          :ok
        end
    end
  end

  def handle_event(_event), do: :ok

  defp enqueue_email(user_id, inviter_name, group_name, accept_url) do
    args = %{
      "template" => "group_invitation",
      "user_id" => user_id,
      "params" => %{
        "inviter_name" => inviter_name,
        "group_name" => group_name,
        "accept_url" => accept_url
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
