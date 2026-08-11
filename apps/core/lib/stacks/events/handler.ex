defmodule Stacks.Events.Handler do
  @moduledoc """
      Behaviour for event-bus subscribers. `handle_event/1` receives the full
      event map as stored in `op.event_log` and returns `:ok` or
      `{:error, reason}`. Register implementations in
      `Stacks.Events.Registry`.

          @impl true
          def handle_event(%{event_type: "user.registered"} = event) do
            send_welcome_email(event.payload)
  :ok
          end
  """

  @callback handle_event(event :: map()) :: :ok | {:error, term()}
end
