defmodule Stacks.EventsTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query

  alias Stacks.Events

  describe "emit/1" do
    test "inserts an event and returns {:ok, params}" do
      assert {:ok, params} =
               Events.emit(%{
                 event_type: "test.event",
                 aggregate_type: "test",
                 aggregate_id: Ecto.UUID.generate()
               })

      assert params.event_type == "test.event"
    end

    test "includes optional payload and metadata" do
      id = Ecto.UUID.generate()

      assert {:ok, params} =
               Events.emit(%{
                 event_type: "test.with_payload",
                 aggregate_type: "test",
                 aggregate_id: id,
                 payload: %{key: "value"},
                 metadata: %{source: "test"}
               })

      assert params.payload == %{key: "value"}
    end

    test "returns {:error, _} when aggregate_id is not a valid UUID" do
      assert {:error, _reason} =
               Events.emit(%{
                 event_type: "test.bad_id",
                 aggregate_type: "test",
                 aggregate_id: "not-a-uuid"
               })
    end

    test "enqueues a SubscriberWorker job after persisting event" do
      assert {:ok, params} =
               Events.emit(%{
                 event_type: "test.enqueue",
                 aggregate_type: "test",
                 aggregate_id: Ecto.UUID.generate()
               })

      event_id = Ecto.UUID.cast!(params.id)
      assert_enqueued(worker: Stacks.Events.SubscriberWorker, args: %{event_id: event_id})
    end
  end

  describe "emit/1 schema_version" do
    test "emitted event has schema_version 1 by default" do
      agg_id = Ecto.UUID.generate()

      assert {:ok, _params} =
               Events.emit(%{
                 event_type: "schema.default",
                 aggregate_type: "test",
                 aggregate_id: agg_id
               })

      row =
        Core.Repo.one(
          from(e in "event_log",
            where: e.event_type == "schema.default",
            select: %{schema_version: e.schema_version}
          ),
          prefix: "op"
        )

      assert row.schema_version == 1
    end

    test "schema_version can be overridden by caller" do
      agg_id = Ecto.UUID.generate()

      assert {:ok, _params} =
               Events.emit(%{
                 event_type: "schema.override",
                 aggregate_type: "test",
                 aggregate_id: agg_id,
                 schema_version: 2
               })

      row =
        Core.Repo.one(
          from(e in "event_log",
            where: e.event_type == "schema.override",
            select: %{schema_version: e.schema_version}
          ),
          prefix: "op"
        )

      assert row.schema_version == 2
    end
  end

  describe "emit_safe/1" do
    test "returns {:ok, params} on success" do
      assert {:ok, _} =
               Events.emit_safe(%{
                 event_type: "safe.event",
                 aggregate_type: "safe",
                 aggregate_id: Ecto.UUID.generate()
               })
    end

    test "returns {:ok, event} and does not raise when emit fails" do
      event = %{
        event_type: "safe.bad",
        aggregate_type: "safe",
        aggregate_id: "not-a-uuid"
      }

      assert {:ok, ^event} = Events.emit_safe(event)
    end
  end

  describe "replay/3" do
    defmodule TestHandler do
      @behaviour Stacks.Events.Handler

      @impl true
      def handle_event(event) do
        send(self(), {:replayed, event.event_type})
        :ok
      end
    end

    test "replays events of the given type to a handler" do
      agg_id = Ecto.UUID.generate()

      for i <- 1..3 do
        Events.emit(%{
          event_type: "replay.target",
          aggregate_type: "test",
          aggregate_id: agg_id,
          payload: %{index: i}
        })
      end

      Events.emit(%{
        event_type: "replay.other",
        aggregate_type: "test",
        aggregate_id: agg_id
      })

      from = DateTime.add(DateTime.utc_now(), -60, :second)
      assert {:ok, 3} = Events.replay("replay.target", from, TestHandler)

      assert_received {:replayed, "replay.target"}
      assert_received {:replayed, "replay.target"}
      assert_received {:replayed, "replay.target"}
      refute_received {:replayed, "replay.other"}
    end

    test "returns {:ok, 0} when no events match" do
      from = DateTime.utc_now()
      assert {:ok, 0} = Events.replay("nonexistent.type", from, TestHandler)
    end
  end
end
