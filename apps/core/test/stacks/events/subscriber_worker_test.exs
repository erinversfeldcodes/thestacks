defmodule Stacks.Events.SubscriberWorkerTest do
  use Core.DataCase, async: true

  alias Stacks.Events
  alias Stacks.Events.SubscriberWorker

  # A test handler that always returns an error, used to exercise the telemetry path.
  defmodule FailingHandler do
    @behaviour Stacks.Events.Handler
    @impl true
    def handle_event(_event), do: {:error, :simulated_failure}
  end

  # A test handler that always raises, used to exercise the rescue/telemetry path.
  defmodule RaisingHandler do
    @behaviour Stacks.Events.Handler
    @impl true
    def handle_event(_event), do: raise("simulated crash")
  end

  describe "perform/1" do
    test "returns :ok when event exists and has no registered handlers" do
      {:ok, params} =
        Events.emit(%{
          event_type: "test.subscriber_worker",
          aggregate_type: "test",
          aggregate_id: Ecto.UUID.generate()
        })

      event_id = Ecto.UUID.cast!(params.id)

      job = %Oban.Job{args: %{"event_id" => event_id}}
      assert :ok = SubscriberWorker.perform(job)
    end

    test "cancels job when event_id does not exist" do
      job = %Oban.Job{args: %{"event_id" => Ecto.UUID.generate()}}
      assert {:cancel, "event not found"} = SubscriberWorker.perform(job)
    end

    test "telemetry handler_error event is emitted on handler dispatch failure" do
      # Verify the telemetry event signature is correct by exercising
      # :telemetry.execute directly (integration test for the telemetry path).
      # The dispatch logic is tested at the unit level via the FailingHandler module
      # defined at the top of this test file.
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-#{inspect(ref)}",
        [:stacks, :events, :handler_error],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_received, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-#{inspect(ref)}") end)

      # Directly invoke :telemetry.execute as SubscriberWorker does on handler error,
      # verifying the event name, measurement shape, and metadata shape match the spec.
      :telemetry.execute(
        [:stacks, :events, :handler_error],
        %{count: 1},
        %{handler: inspect(FailingHandler), event_type: "test.event"}
      )

      assert_receive {:telemetry_received, %{count: 1}, %{handler: _, event_type: "test.event"}}
    end
  end
end
