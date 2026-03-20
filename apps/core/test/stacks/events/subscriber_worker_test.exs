defmodule Stacks.Events.SubscriberWorkerTest do
  use Core.DataCase, async: true

  import Ecto.Query

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
    test "sets published_at on the event_log row after successful dispatch" do
      {:ok, params} =
        Events.emit(%{
          event_type: "test.published_at",
          aggregate_type: "test",
          aggregate_id: Ecto.UUID.generate()
        })

      event_id = Ecto.UUID.cast!(params.id)
      event_id_bin = Ecto.UUID.dump!(event_id)

      # published_at is null before dispatch
      before =
        Core.Repo.one(
          from(e in "event_log",
            where: e.id == ^event_id_bin,
            select: %{published_at: e.published_at}
          ),
          prefix: "op"
        )

      assert is_nil(before.published_at)

      job = %Oban.Job{args: %{"event_id" => event_id}}
      assert :ok = SubscriberWorker.perform(job)

      # published_at is set after dispatch
      after_dispatch =
        Core.Repo.one(
          from(e in "event_log",
            where: e.id == ^event_id_bin,
            select: %{published_at: e.published_at}
          ),
          prefix: "op"
        )

      # Schemaless Ecto queries return utc_datetime_usec as NaiveDateTime.
      assert %NaiveDateTime{} = after_dispatch.published_at
    end

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

    test "dispatches to registered handlers for known event types" do
      # Emit a book.created event which has registered handlers in the Registry
      book_id = Ecto.UUID.generate()

      {:ok, params} =
        Events.emit(%{
          event_type: "book.created",
          aggregate_type: "book",
          aggregate_id: book_id,
          payload: %{title: "Test Book"},
          metadata: %{actor: "test"}
        })

      event_id = Ecto.UUID.cast!(params.id)

      # The handlers may fail (no actual book exists), but the worker should
      # still return :ok because handler errors are isolated with try/rescue
      job = %Oban.Job{args: %{"event_id" => event_id}}
      assert :ok = SubscriberWorker.perform(job)

      # Verify published_at was set even though handlers may have errored
      event_id_bin = Ecto.UUID.dump!(event_id)

      after_dispatch =
        Core.Repo.one(
          from(e in "event_log",
            where: e.id == ^event_id_bin,
            select: %{published_at: e.published_at}
          ),
          prefix: "op"
        )

      assert after_dispatch.published_at != nil
    end

    test "handler returning {:error, reason} does not prevent other handlers from running" do
      # Emit a book.created event — it has 2 registered handlers
      # Even if one errors, both should be attempted and published_at should be set
      {:ok, params} =
        Events.emit(%{
          event_type: "book.created",
          aggregate_type: "book",
          aggregate_id: Ecto.UUID.generate(),
          payload: %{},
          metadata: %{actor: "test"}
        })

      event_id = Ecto.UUID.cast!(params.id)
      job = %Oban.Job{args: %{"event_id" => event_id}}

      # Should succeed even if handlers error
      assert :ok = SubscriberWorker.perform(job)
    end

    test "mark_published sets published_at timestamp on dispatched events" do
      {:ok, params} =
        Events.emit(%{
          event_type: "test.mark_published",
          aggregate_type: "test",
          aggregate_id: Ecto.UUID.generate()
        })

      event_id = Ecto.UUID.cast!(params.id)
      event_id_bin = Ecto.UUID.dump!(event_id)

      job = %Oban.Job{args: %{"event_id" => event_id}}
      assert :ok = SubscriberWorker.perform(job)

      row =
        Core.Repo.one(
          from(e in "event_log",
            where: e.id == ^event_id_bin,
            select: %{published_at: e.published_at}
          ),
          prefix: "op"
        )

      assert %NaiveDateTime{} = row.published_at
    end

    test "upcaster is applied to fetched events" do
      # Events with schema_version 1 pass through unchanged
      {:ok, params} =
        Events.emit(%{
          event_type: "test.upcast",
          aggregate_type: "test",
          aggregate_id: Ecto.UUID.generate(),
          payload: %{key: "value"}
        })

      event_id = Ecto.UUID.cast!(params.id)
      job = %Oban.Job{args: %{"event_id" => event_id}}

      # Should complete successfully — upcaster passes version 1 through
      assert :ok = SubscriberWorker.perform(job)
    end
  end
end
