defmodule Stacks.Books.Handlers.CacheInvalidationHandlerTest do
  use Core.DataCase, async: true

  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.Handlers.CacheInvalidationHandler

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
    assert {:ok, _} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)

    event1 = %{event_type: "book.created", aggregate_id: id1, payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event1)

    assert {:miss, ^id1} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)

    event2 = %{event_type: "book.created", aggregate_id: id2, payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event2)

    assert {:miss, ^id2} = BookDetailCache.get(id2)
  end

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

  test "a payload with no work id degrades to the TTL rather than raising", %{id1: id1} do
    event = %{
      event_type: "books.edition_merged",
      aggregate_id: "edition-new-3",
      payload: %{"isbn" => "9780099466031"}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:ok, _} = BookDetailCache.get(id1)
  end

  test "invalidates the work on book.visibility_tier_changed", %{id1: id1, id2: id2} do
    event = %{
      event_type: "book.visibility_tier_changed",
      aggregate_type: "book",
      aggregate_id: id1,
      payload: %{"book_id" => id1, "visibility_tier" => "age_gated"}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id1} = BookDetailCache.get(id1)
    assert {:ok, _} = BookDetailCache.get(id2)
  end

  test "invalidates on book.visibility_tier_changed with atom payload keys", %{id2: id2} do
    event = %{
      event_type: "book.visibility_tier_changed",
      aggregate_id: id2,
      payload: %{book_id: id2, visibility_tier: "age_gated"}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id2} = BookDetailCache.get(id2)
  end

  test "invalidates the enriched work on book.enriched", %{id1: id1, id2: id2} do
    event = %{
      event_type: "book.enriched",
      aggregate_type: "book",
      aggregate_id: id2,
      payload: %{"book_id" => id2}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id2} = BookDetailCache.get(id2)
    assert {:ok, _} = BookDetailCache.get(id1)
  end

  test "invalidates on book.enriched with atom payload keys", %{id1: id1} do
    event = %{event_type: "book.enriched", aggregate_id: id1, payload: %{book_id: id1}}

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, ^id1} = BookDetailCache.get(id1)
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
