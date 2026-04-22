defmodule Stacks.Books.TitleSearchCacheTest do
  use ExUnit.Case, async: false

  alias Stacks.Books.TitleSearchCache

  setup do
    # ETS is global — isolate per test by flushing before each.
    TitleSearchCache.invalidate_all()
    :ok
  end

  describe "get/3 + put/4" do
    test "miss returns :miss for an unknown (title, author, raw_text) triple" do
      assert :miss = TitleSearchCache.get("Unknown Book", "Unknown Author", nil)
    end

    test "put stores and get returns a positive result" do
      meta = %{title: "Gatsby", source: :open_library}

      :ok =
        TitleSearchCache.put(
          "The Great Gatsby",
          "F. Scott Fitzgerald",
          nil,
          {:ok, "9780743273565", meta}
        )

      assert {:ok, {:ok, "9780743273565", ^meta}} =
               TitleSearchCache.get("The Great Gatsby", "F. Scott Fitzgerald", nil)
    end

    test "put stores and get returns a negative result" do
      :ok = TitleSearchCache.put("Fake Title", "Fake Author", nil, {:error, :not_found})

      assert {:ok, {:error, :not_found}} =
               TitleSearchCache.get("Fake Title", "Fake Author", nil)
    end

    test "non-canonical terms (e.g. :circuit_open) are NOT cached" do
      :ok = TitleSearchCache.put("X", "Y", nil, {:error, :circuit_open})
      assert :miss = TitleSearchCache.get("X", "Y", nil)
    end

    test "whitespace and case variations collapse to the same cache entry" do
      :ok =
        TitleSearchCache.put(
          "The Great Gatsby",
          "F. Scott Fitzgerald",
          nil,
          {:ok, "9780743273565", %{}}
        )

      # Lowercase + extra whitespace both hit the same key.
      assert {:ok, {:ok, "9780743273565", _}} =
               TitleSearchCache.get("  the great gatsby  ", "f. scott fitzgerald", nil)
    end

    test "raw_text variations produce distinct cache entries" do
      :ok = TitleSearchCache.put("Circe", "Miller", "first pass", {:ok, "9780316556347", %{}})
      :ok = TitleSearchCache.put("Circe", "Miller", "different pass", {:error, :not_found})

      assert {:ok, {:ok, _, _}} = TitleSearchCache.get("Circe", "Miller", "first pass")

      assert {:ok, {:error, :not_found}} =
               TitleSearchCache.get("Circe", "Miller", "different pass")
    end

    test "nil author vs empty author collapse to the same entry" do
      :ok = TitleSearchCache.put("Dune", nil, nil, {:ok, "9780441172719", %{}})
      assert {:ok, {:ok, _, _}} = TitleSearchCache.get("Dune", "", nil)
    end

    test "invalidate_all/0 empties the cache" do
      TitleSearchCache.put("A", "a", nil, {:ok, "9780000000001", %{}})
      TitleSearchCache.put("B", "b", nil, {:ok, "9780000000002", %{}})
      :ok = TitleSearchCache.invalidate_all()
      assert :miss = TitleSearchCache.get("A", "a", nil)
      assert :miss = TitleSearchCache.get("B", "b", nil)
    end
  end
end
