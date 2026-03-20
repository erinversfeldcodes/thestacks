defmodule Stacks.Enrichment.EventsTest do
  use Core.DataCase, async: true

  alias Stacks.Enrichment.Events

  import Stacks.Factory

  describe "upsert_event/1" do
    test "inserts a new bookstore event" do
      store = insert(:bookstore)

      attrs = %{
        store_id: store.id,
        title: "Author Reading Night",
        description: "Join us for an evening with the author.",
        event_date: DateTime.add(DateTime.utc_now(), 7, :day),
        location: "Main floor",
        url: "https://example.com/events/reading-night",
        scraped_at: DateTime.utc_now()
      }

      assert {:ok, event} = Events.upsert_event(attrs)
      assert event.title == "Author Reading Night"
      assert event.store_id == store.id
    end

    test "upserts on conflict (store_id, title, event_date)" do
      store = insert(:bookstore)
      event_date = DateTime.add(DateTime.utc_now(), 7, :day)

      attrs = %{
        store_id: store.id,
        title: "Book Launch",
        event_date: event_date,
        description: "First description",
        scraped_at: DateTime.utc_now()
      }

      assert {:ok, first} = Events.upsert_event(attrs)

      updated_attrs = %{attrs | description: "Updated description"}
      assert {:ok, second} = Events.upsert_event(updated_attrs)

      # Same record, updated description
      assert first.id == second.id
      assert second.description == "Updated description"
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Events.upsert_event(%{})
      assert %{store_id: _, title: _, scraped_at: _} = errors_on(changeset)
    end
  end

  describe "upcoming_events/1" do
    test "returns future events for a store" do
      store = insert(:bookstore)
      future_date = DateTime.add(DateTime.utc_now(), 7, :day)
      past_date = DateTime.add(DateTime.utc_now(), -7, :day)

      insert(:bookstore_event, store: store, event_date: future_date, title: "Future Event")
      insert(:bookstore_event, store: store, event_date: past_date, title: "Past Event")

      events = Events.upcoming_events(store.id)
      assert length(events) == 1
      assert hd(events).title == "Future Event"
    end

    test "returns empty list when no upcoming events" do
      store = insert(:bookstore)
      assert Events.upcoming_events(store.id) == []
    end
  end

  describe "upsert_third_space_event/1" do
    test "inserts a new third space event" do
      space = insert(:third_space)

      attrs = %{
        space_id: space.id,
        title: "Book Club Meeting",
        description: "Monthly reading group.",
        event_date: DateTime.add(DateTime.utc_now(), 14, :day),
        recurrence: "monthly",
        related_authors: ["Author One"],
        source_url: "https://example.com/book-club",
        scraped_at: DateTime.utc_now()
      }

      assert {:ok, event} = Events.upsert_third_space_event(attrs)
      assert event.title == "Book Club Meeting"
      assert event.space_id == space.id
      assert event.related_authors == ["Author One"]
    end

    test "upserts on conflict (space_id, title, event_date)" do
      space = insert(:third_space)
      event_date = DateTime.add(DateTime.utc_now(), 14, :day)

      attrs = %{
        space_id: space.id,
        title: "Poetry Night",
        event_date: event_date,
        description: "Original",
        scraped_at: DateTime.utc_now()
      }

      assert {:ok, first} = Events.upsert_third_space_event(attrs)

      updated_attrs = %{attrs | description: "Updated"}
      assert {:ok, second} = Events.upsert_third_space_event(updated_attrs)

      assert first.id == second.id
      assert second.description == "Updated"
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Events.upsert_third_space_event(%{})
      assert %{space_id: _, title: _, scraped_at: _} = errors_on(changeset)
    end
  end

  describe "upcoming_third_space_events/1" do
    test "returns future events for a space" do
      space = insert(:third_space)
      future_date = DateTime.add(DateTime.utc_now(), 7, :day)
      past_date = DateTime.add(DateTime.utc_now(), -7, :day)

      insert(:third_space_event, space: space, event_date: future_date, title: "Future")
      insert(:third_space_event, space: space, event_date: past_date, title: "Past")

      events = Events.upcoming_third_space_events(space.id)
      assert length(events) == 1
      assert hd(events).title == "Future"
    end
  end
end
