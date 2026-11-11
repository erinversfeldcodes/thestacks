defmodule Stacks.Books.BookDetailCacheTest do
  @moduledoc """
      ⚠️ `async: false`, and it must stay that way: the `setup` below calls
      `invalidate_all/0`, which is `:ets.delete_all_objects` on a `:named_table,
      :public` cache shared by the whole run.

      Run async, this file wipes that table out from under any concurrent test
      that put something in it. That was the cause of a genuine race in
      `CacheInvalidationHandlerTest` "ignores unrelated events" — it failed once
      under seed 564411 and then passed on a re-run of the SAME seed, which is
      the signature of concurrency rather than ordering. Everything that
      investigation ruled out was correctly ruled out: the handler test's ids are
      uniquified so it was never a key collision, and the cache's 300s TTL and
      60s sweep are both longer than a whole suite run so it was never expiry.
      It was this `delete_all_objects`.

      Every one of the eleven sibling tests that clears a shared cache is
      already `async: false` — the convention existed and this file was the one
      exception. `test/platform/async_cache_clearing_test.sh` now holds the rule
      so the exception cannot come back.
  """
  use ExUnit.Case, async: false

  alias Stacks.Books.BookDetailCache

  setup do
    BookDetailCache.invalidate_all()
    :ok
  end

  describe "get/1" do
    test "returns {:miss, book_id} for uncached entries" do
      id = Ecto.UUID.generate()
      assert {:miss, ^id} = BookDetailCache.get(id)
    end
  end

  describe "put/1 + get/1" do
    test "returns cached data" do
      id = Ecto.UUID.generate()
      data = %{title: "Circe", author: "Madeline Miller"}

      assert :ok = BookDetailCache.put(id, data)
      assert {:ok, ^data} = BookDetailCache.get(id)
    end
  end

  describe "invalidate/1" do
    test "removes a specific entry" do
      id = Ecto.UUID.generate()
      BookDetailCache.put(id, %{title: "Test"})

      assert {:ok, _} = BookDetailCache.get(id)

      BookDetailCache.invalidate(id)

      assert {:miss, ^id} = BookDetailCache.get(id)
    end
  end

  describe "invalidate_all/0" do
    test "clears all entries" do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      BookDetailCache.put(id1, %{title: "A"})
      BookDetailCache.put(id2, %{title: "B"})

      BookDetailCache.invalidate_all()

      assert {:miss, _} = BookDetailCache.get(id1)
      assert {:miss, _} = BookDetailCache.get(id2)
    end
  end

  describe "TTL expiry" do
    test "expired entries return :miss" do
      id = Ecto.UUID.generate()
      expired_at = System.monotonic_time(:millisecond) - 360_000
      :ets.insert(:book_detail_cache, {id, %{title: "Old"}, expired_at})

      assert {:miss, ^id} = BookDetailCache.get(id)
    end
  end
end
