defmodule Stacks.Books.TitleSearchCachePersistentTest do
  @moduledoc """
  Exercises the Postgres L2 layer of `Stacks.Books.TitleSearchCache`.
  See `ISBNResolverCachePersistentTest` for the rationale on opting
  into persistent mode per-test rather than globally in test env.
  """

  use Core.DataCase, async: false

  alias Stacks.Books.TitleSearchCache
  alias Stacks.Books.TitleSearchCacheEntry

  setup do
    original = Application.get_env(:core, :persistent_cache_enabled)
    Application.put_env(:core, :persistent_cache_enabled, true)
    on_exit(fn -> Application.put_env(:core, :persistent_cache_enabled, original) end)

    TitleSearchCache.invalidate_all()

    :ok
  end

  describe "L2 persistence" do
    test "put writes a positive result with inputs, isbn, metadata, and 24h TTL" do
      meta = %{source: :open_library, publication_year: 1965}

      :ok =
        TitleSearchCache.put(
          "Dune",
          "Frank Herbert",
          "raw hint",
          {:ok, "9780441172719", meta}
        )

      row = Repo.one(TitleSearchCacheEntry)
      assert row.outcome == "found"
      assert row.isbn == "9780441172719"
      assert row.title == "Dune"
      assert row.author == "Frank Herbert"
      assert row.raw_text == "raw hint"
      assert row.metadata["source"] == "open_library"
      assert row.metadata["publication_year"] == 1965
      assert DateTime.diff(row.expires_at, DateTime.utc_now()) > 23 * 60 * 60
    end

    test "put writes a negative result with empty isbn and 1h TTL" do
      :ok = TitleSearchCache.put("Fake", "Fake", nil, {:error, :not_found})

      row = Repo.one(TitleSearchCacheEntry)
      assert row.outcome == "not_found"
      assert row.isbn == ""
      assert row.metadata == nil
      ttl = DateTime.diff(row.expires_at, DateTime.utc_now())
      assert ttl > 50 * 60
      assert ttl < 65 * 60
    end

    test ":circuit_open is not persisted" do
      :ok = TitleSearchCache.put("X", "Y", nil, {:error, :circuit_open})
      assert Repo.all(TitleSearchCacheEntry) == []
    end

    test "get falls through to Postgres on ETS miss" do
      :ok =
        TitleSearchCache.put(
          "Circe",
          "Miller",
          nil,
          {:ok, "9780316556347", %{source: :google_books}}
        )

      :ets.delete_all_objects(:title_search_cache)

      assert {:ok, {:ok, "9780316556347", meta}} = TitleSearchCache.get("Circe", "Miller", nil)
      assert meta.source == :google_books
    end

    test "normalisation collapses whitespace/case in the cache_key used for lookup" do
      :ok =
        TitleSearchCache.put("The Great Gatsby", "Fitzgerald", nil, {:ok, "9780743273565", %{}})

      :ets.delete_all_objects(:title_search_cache)

      assert {:ok, {:ok, "9780743273565", _}} =
               TitleSearchCache.get("  THE great GATSBY  ", "fitzgerald", nil)
    end

    test "expired Postgres rows are treated as a miss" do
      now = DateTime.utc_now()

      {1, _} =
        Repo.insert_all(TitleSearchCacheEntry, [
          %{
            cache_key: "stale\x1fauthor\x1f",
            title: "stale",
            author: "author",
            raw_text: "",
            outcome: "found",
            isbn: "9780000000000",
            metadata: %{},
            expires_at: DateTime.add(now, -60, :second),
            created_at: now,
            updated_at: now
          }
        ])

      assert :miss = TitleSearchCache.get("stale", "author", nil)
    end

    test "put upserts an existing cache_key row" do
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:ok, "9780441172719", %{v: 1}})
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:ok, "9780441172719", %{v: 2}})

      assert [row] = Repo.all(TitleSearchCacheEntry)
      assert row.metadata["v"] == 2
    end

    test "invalidate_all/0 clears all rows" do
      :ok = TitleSearchCache.put("A", "a", nil, {:ok, "9780000000001", %{}})
      :ok = TitleSearchCache.put("B", "b", nil, {:ok, "9780000000002", %{}})

      :ok = TitleSearchCache.invalidate_all()

      assert Repo.all(TitleSearchCacheEntry) == []
    end
  end
end
