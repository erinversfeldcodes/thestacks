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

    # Characterization test (Issue #118, punch #2): pins the exact handler set
    # and order for `book.created`. US-4.1 §6 previously listed a stale
    # DbtRefreshHandler here — it is NOT subscribed to `book.created` (only
    # `placement.created`). AuthorDiscoveryHandler IS subscribed but is an
    # intentional no-op on book.created. This asserts already-correct behaviour
    # and would fail if the registry (registry.ex:19-23) drifted.
    test "book.created subscribes exactly the three enrichment/cache handlers in order" do
      assert Registry.handlers_for("book.created") == [
               Stacks.Enrichment.Handlers.BookCreatedHandler,
               Stacks.Enrichment.Handlers.AuthorDiscoveryHandler,
               Stacks.Books.Handlers.CacheInvalidationHandler
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
  end
end
