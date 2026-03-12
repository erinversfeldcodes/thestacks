defmodule Stacks.EventsTest do
  use Core.DataCase, async: true

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
      # encode_uuid/1 returns nil for non-UUID strings; the NOT NULL constraint fires.
      assert {:error, _reason} =
               Events.emit(%{
                 event_type: "test.bad_id",
                 aggregate_type: "test",
                 aggregate_id: "not-a-uuid"
               })
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

      # emit would return {:error, _}; emit_safe swallows it
      assert {:ok, ^event} = Events.emit_safe(event)
    end
  end
end
