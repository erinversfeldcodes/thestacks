defmodule Stacks.Events.UpcasterTest do
  use ExUnit.Case, async: true

  alias Stacks.Events.Upcaster

  describe "upcast/1" do
    test "passes through version 1 events unchanged" do
      event = %{
        event_type: "book.created",
        schema_version: 1,
        payload: %{isbn: "978-0-13-110362-7"}
      }

      assert Upcaster.upcast(event) == event
    end

    test "passes through unknown versions unchanged (forward compatibility)" do
      event = %{
        event_type: "book.created",
        schema_version: 999,
        payload: %{isbn: "978-0-13-110362-7"}
      }

      assert Upcaster.upcast(event) == event
    end

    test "passes through events without schema_version" do
      event = %{event_type: "legacy.event", payload: %{}}
      assert Upcaster.upcast(event) == event
    end
  end
end
