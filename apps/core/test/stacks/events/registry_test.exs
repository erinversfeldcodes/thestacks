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

    # US-1.6.6: the reading-lifecycle events are emitted by
    # Shelving.update_reading_progress/3 and registered with an EMPTY handler
    # set (stg_bookshelf_placements is a dbt view — always live — and no mart
    # consumes reading progress today, so no handler is warranted). Registration
    # keeps them in the catalog (all_event_types/0) without a phantom handler.
    test "reading-lifecycle events are registered with an empty handler set" do
      # handlers_for/1 returns [] for an UNREGISTERED type too (registry.ex
      # falls back to Map.get(@registry, t, [])), so the empty-set assertion is
      # vacuous on its own. Pin it to actual registration by also asserting the
      # types appear in the catalog (all_event_types/0 only lists @registry keys).
      assert Registry.handlers_for("placement.reading_started") == []
      assert Registry.handlers_for("placement.reading_completed") == []

      types = Registry.all_event_types()
      assert "placement.reading_started" in types
      assert "placement.reading_completed" in types
    end

    # US-1.6.3 / Issue #116 punch #11: placement.reread (emitted by
    # Shelving.reread_book/2) is registered with an EMPTY handler set — matching
    # the reading-lifecycle events and preserving its pre-existing no-handler
    # behaviour. As above, the []-assertion is vacuous alone (unregistered types
    # also return []), so it is pinned to real registration via all_event_types/0.
    test "placement.reread is registered with an empty handler set" do
      assert Registry.handlers_for("placement.reread") == []
      assert "placement.reread" in Registry.all_event_types()
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
