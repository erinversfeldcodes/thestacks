defmodule Stacks.Books.Handlers.CacheInvalidationHandlerTest do
  use Core.DataCase, async: true

  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.Handlers.CacheInvalidationHandler

  setup do
    BookDetailCache.put("book-1", %{title: "Test Book"})
    BookDetailCache.put("book-2", %{title: "Other Book"})
    :ok
  end

  test "invalidates cache on book.created" do
    event = %{event_type: "book.created", aggregate_id: "book-1", payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, "book-1"} = BookDetailCache.get("book-1")
    assert {:ok, _} = BookDetailCache.get("book-2")
  end

  test "invalidates cache on book.cover_confirmed" do
    event = %{event_type: "book.cover_confirmed", aggregate_id: "book-2", payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, "book-2"} = BookDetailCache.get("book-2")
  end

  test "invalidates multiple books on blog.associations_suggested with string keys" do
    event = %{
      event_type: "blog.associations_suggested",
      aggregate_id: "post-1",
      payload: %{"book_ids" => ["book-1", "book-2"]}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, "book-1"} = BookDetailCache.get("book-1")
    assert {:miss, "book-2"} = BookDetailCache.get("book-2")
  end

  test "invalidates multiple books on blog.associations_suggested with atom keys" do
    event = %{
      event_type: "blog.associations_suggested",
      aggregate_id: "post-1",
      payload: %{book_ids: ["book-1"]}
    }

    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:miss, "book-1"} = BookDetailCache.get("book-1")
    assert {:ok, _} = BookDetailCache.get("book-2")
  end

  test "ignores unrelated events" do
    event = %{event_type: "user.registered", aggregate_id: "user-1", payload: %{}}
    assert :ok = CacheInvalidationHandler.handle_event(event)
    assert {:ok, _} = BookDetailCache.get("book-1")
  end
end
