defmodule Stacks.Events.RegistryTest do
  use ExUnit.Case, async: true

  alias Stacks.Events.Registry

  describe "handlers_for/1" do
    test "returns empty list for unregistered event type" do
      assert Registry.handlers_for("nonexistent.event") == []
    end

    test "returns empty list for empty string" do
      assert Registry.handlers_for("") == []
    end

    test "book.created subscribes exactly the three enrichment/cache handlers in order" do
      assert Registry.handlers_for("book.created") == [
               Stacks.Enrichment.Handlers.BookCreatedHandler,
               Stacks.Enrichment.Handlers.AuthorDiscoveryHandler,
               Stacks.Books.Handlers.CacheInvalidationHandler
             ]
    end

    test "reading-lifecycle events are registered with an empty handler set" do
      assert Registry.handlers_for("placement.reading_started") == []
      assert Registry.handlers_for("placement.reading_completed") == []

      types = Registry.all_event_types()
      assert "placement.reading_started" in types
      assert "placement.reading_completed" in types
    end

    test "placement.reread is registered with an empty handler set" do
      assert Registry.handlers_for("placement.reread") == []
      assert "placement.reread" in Registry.all_event_types()
    end

    test "placement.removed subscribes the feed handler and the dbt refresh handler" do
      assert Registry.handlers_for("placement.removed") == [
               Stacks.Feeds.Handlers.PlacementHandler,
               Stacks.Workers.DbtRefreshHandler
             ]
    end
  end

  describe "all_event_types/0" do
    test "returns a list" do
      assert is_list(Registry.all_event_types())
    end

    test "all entries are strings" do
      assert Enum.all?(Registry.all_event_types(), &is_binary/1)
    end

    test "catalogues the reading-lifecycle event types (US-1.6.6)" do
      types = Registry.all_event_types()
      assert "placement.reading_started" in types
      assert "placement.reading_completed" in types
    end
  end
end
