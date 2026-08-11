defmodule Stacks.Books.BookDetailCacheTest do
  use ExUnit.Case, async: true

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
