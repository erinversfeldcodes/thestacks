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

  # ⚠️ This test used to build the event as
  # `%{aggregate_id: <a book id>, payload: %{}}` and assert the handler evicted
  # that key. It passed for as long as the handler read `aggregate_id` — and
  # `Books.confirm_cover_association/2` has never emitted that shape. It
  # aggregates the EDITION (`aggregate_type: "book_edition"`), so the handler
  # was evicting under an edition id: a key that is never in a book-keyed cache.
  # A confirmed cover therefore stayed invisible for the full 5-minute TTL, with
  # the handler, the registry and this test all green. Found by #355's sibling
  # sweep; the events below are the shape the emitter actually produces.
  test "invalidates the WORK on book.cover_confirmed, not the edition the event aggregates",
       %{id1: id1, id2: id2} do
    event = %{
      event_type: "book.cover_confirmed",
      aggregate_type: "book_edition",
      aggregate_id: "edition-that-is-not-a-cache-key",
      payload: %{"book_id" => id2, "cover_image_url" => "https://example.test/c.jpg"}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id2} = BookDetailCache.get(id2)
    assert {:ok, _} = BookDetailCache.get(id1)
  end

  test "invalidates on book.cover_confirmed with atom payload keys", %{id1: id1} do
    event = %{
      event_type: "book.cover_confirmed",
      aggregate_id: "edition-1",
      payload: %{book_id: id1, cover_image_url: "https://example.test/c.jpg"}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id1} = BookDetailCache.get(id1)
  end

  # US-1.1.8. `merge_edition/2` aggregates the new EDITION and names the work it
  # was merged into as `work_id` — the same aggregate/cache-key mismatch as
  # cover_confirmed, and the reason #355's reader was shown a book without the
  # edition they had just added.
  test "invalidates the merged-into work on books.edition_merged", %{id1: id1, id2: id2} do
    event = %{
      event_type: "books.edition_merged",
      aggregate_type: "book_edition",
      aggregate_id: "edition-new-1",
      payload: %{"isbn" => "9780099466031", "work_id" => id1}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id1} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)
  end

  test "invalidates on books.edition_merged with atom payload keys", %{id2: id2} do
    event = %{
      event_type: "books.edition_merged",
      aggregate_id: "edition-new-2",
      payload: %{isbn: "9780099466031", work_id: id2}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id2} = BookDetailCache.get(id2)
  end

  # Historical rows predate the payload key (see PayloadContract). Degrade to
  # the TTL; never crash the dispatch, which would take the other handlers on
  # that event down with it.
  test "a payload with no work id degrades to the TTL rather than raising", %{id1: id1} do
    event = %{
      event_type: "books.edition_merged",
      aggregate_id: "edition-new-3",
      payload: %{"isbn" => "9780099466031"}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:ok, _} = BookDetailCache.get(id1)
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
