defmodule Stacks.Books.Handlers.CacheInvalidationHandlerTest do
  use Core.DataCase, async: true

  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.Handlers.CacheInvalidationHandler

  # Use per-test unique keys to avoid races with BookDetailCacheTest's
  # invalidate_all() setup that runs concurrently (both modules are async: true).
  setup do
    n = System.unique_integer([:positive])
    id1 = "book-#{n}-1"
    id2 = "book-#{n}-2"

    BookDetailCache.put(id1, %{title: "Test Book"})
    BookDetailCache.put(id2, %{title: "Other Book"})

    {:ok, id1: id1, id2: id2}
  end

  test "invalidates cache on book.created", %{id1: id1, id2: id2} do
    event = %{event_type: "book.created", aggregate_id: id1, payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id1} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)
  end

  @tag stories: ["US-1.1.7"], suite: :cache
  test "two book.created events each invalidate their own cache entry", %{id1: id1, id2: id2} do
    # Both primed in setup already
    assert {:ok, _} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)

    # Invalidate id1 only
    event1 = %{event_type: "book.created", aggregate_id: id1, payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event1)

    # id1 gone, id2 still present
    assert {:miss, ^id1} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)

    # Now invalidate id2
    event2 = %{event_type: "book.created", aggregate_id: id2, payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event2)

    assert {:miss, ^id2} = BookDetailCache.get(id2)
  end

  test "invalidates cache on book.cover_confirmed", %{id1: _id1, id2: id2} do
    event = %{event_type: "book.cover_confirmed", aggregate_id: id2, payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id2} = BookDetailCache.get(id2)
  end

  test "invalidates multiple books on blog.associations_suggested with string keys",
       %{id1: id1, id2: id2} do
    event = %{
      event_type: "blog.associations_suggested",
      aggregate_id: "post-1",
      payload: %{"book_ids" => [id1, id2]}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id1} = BookDetailCache.get(id1)
    assert {:miss, ^id2} = BookDetailCache.get(id2)
  end

  test "invalidates multiple books on blog.associations_suggested with atom keys",
       %{id1: id1, id2: id2} do
    event = %{
      event_type: "blog.associations_suggested",
      aggregate_id: "post-1",
      payload: %{book_ids: [id1]}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id1} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)
  end

  test "ignores unrelated events", %{id1: id1} do
    event = %{event_type: "user.registered", aggregate_id: "user-1", payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:ok, _} = BookDetailCache.get(id1)
  end
end
