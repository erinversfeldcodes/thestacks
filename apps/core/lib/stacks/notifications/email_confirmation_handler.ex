defmodule Stacks.Notifications.EmailConfirmationHandler do
  @moduledoc """
  Event handler that enqueues a registration confirmation email when a new
  user registers and email confirmation is required.

  Implements `Stacks.Events.Handler` and is registered in
  `Stacks.Events.Registry` for the `"user.registered"` event type.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Email

  @impl true
  @spec handle_event(map()) :: :ok | {:error, term()}
  def handle_event(%{event_type: "user.registered", aggregate_id: user_id}) do
    if Application.get_env(:core, :require_email_confirmation, false) do
      user = Stacks.Accounts.get_user(user_id)
      do_send_confirmation(user)
    else
      :ok
    end
  end

  def handle_event(_event), do: :ok

  defp do_send_confirmation(nil) do
    Logger.warning("EmailConfirmationHandler: user not found, skipping confirmation email")
    :ok
  end

  defp do_send_confirmation(user) do
    case Email.send_registration_confirmation(user) do
      {:ok, _user} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "EmailConfirmationHandler: failed to enqueue confirmation email: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
