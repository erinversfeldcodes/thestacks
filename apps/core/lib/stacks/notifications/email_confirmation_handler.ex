defmodule Stacks.Notifications.EmailConfirmationHandler do
  @moduledoc """
  Event handler that enqueues a registration confirmation email when a new
  user registers.

  Implements `Stacks.Events.Handler` and is registered in
  `Stacks.Events.Registry` for the `"user.registered"` event type.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Email

  @impl true
  @spec handle_event(map()) :: :ok | {:error, term()}
  def handle_event(%{event_type: "user.registered", aggregate_id: user_id}) do
    user = Stacks.Accounts.get_user(user_id)
    do_send_confirmation(user)
  end

  def handle_event(_event), do: :ok

  defp do_send_confirmation(nil) do
    Logger.warning("EmailConfirmationHandler: user not found, skipping confirmation email")
    :ok
  end

  # Already confirmed by the time this async handler runs — a confirmation
  # email is pointless, so no-op successfully rather than surfacing
  # :missing_confirmation_token (mark_confirmed/1 nils the token) and putting
  # the SubscriberWorker into retry. Hit routinely by the E2E session-mint
  # helper (Issue #192: register → mark_confirmed before the handler fires),
  # and possible for a real user who confirms extremely fast. Genuinely
  # unconfirmed-but-tokenless users still fall through to the error branch
  # below — that error remains meaningful.
  defp do_send_confirmation(%{email_confirmed: true}) do
    Logger.debug("EmailConfirmationHandler: user already confirmed, skipping confirmation email")

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
