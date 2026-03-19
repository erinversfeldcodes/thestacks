defmodule Stacks.Events.Handler do
  @moduledoc """
  Behaviour for event handlers.

  Any module that wants to receive dispatched events from the event bus must
  implement this behaviour. The `handle_event/1` callback receives the full
  event map (as stored in `op.event_log`) and should return `:ok` on success
  or `{:error, reason}` on failure.

  ## Example

      defmodule MyApp.Notifications.WelcomeHandler do
        @behaviour Stacks.Events.Handler

        @impl true
        def handle_event(%{event_type: "user.registered"} = event) do
          send_welcome_email(event.payload)
          :ok
        end
      end
  """

  @callback handle_event(event :: map()) :: :ok | {:error, term()}
end
