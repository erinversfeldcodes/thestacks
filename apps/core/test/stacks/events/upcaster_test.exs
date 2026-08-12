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

    test "blog.post_* v1 → v2: strips free-text title (string key), bumps version" do
      for type <- ["blog.post_created", "blog.post_updated", "blog.post_published"] do
        event = %{
          event_type: type,
          schema_version: 1,
          payload: %{"user_id" => "u-1", "title" => "My Post", "visibility" => "platform"}
        }

        upcast = Upcaster.upcast(event)

        assert upcast.schema_version == 2
        refute Map.has_key?(upcast.payload, "title")
        assert upcast.payload["user_id"] == "u-1"
        assert upcast.payload["visibility"] == "platform"
      end
    end

    test "blog.post_* already at v2 passes through unchanged" do
      event = %{
        event_type: "blog.post_created",
        schema_version: 2,
        payload: %{"user_id" => "u-1", "visibility" => "platform"}
      }

      assert Upcaster.upcast(event) == event
    end

    test "a non-blog v1 event with a title is NOT stripped (only blog.post_* upcast)" do
      event = %{
        event_type: "book.created",
        schema_version: 1,
        payload: %{"title" => "A Book", "isbn" => "978-0-13-110362-7"}
      }

      assert Upcaster.upcast(event) == event
    end
  end
end
