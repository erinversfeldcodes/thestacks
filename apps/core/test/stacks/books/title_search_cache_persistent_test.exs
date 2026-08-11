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

      TitleSearchCache.await_pending_writes()

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
      TitleSearchCache.await_pending_writes()

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
      TitleSearchCache.await_pending_writes()
      assert Repo.all(TitleSearchCacheEntry) == []
    end

    test ":unavailable is not persisted" do
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:error, :unavailable})
      TitleSearchCache.await_pending_writes()
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

      TitleSearchCache.await_pending_writes()

      :ets.delete_all_objects(:title_search_cache)

      assert {:ok, {:ok, "9780316556347", meta}} = TitleSearchCache.get("Circe", "Miller", nil)
      assert meta.source == :google_books
    end

    test "normalisation collapses whitespace/case in the cache_key used for lookup" do
      :ok =
        TitleSearchCache.put("The Great Gatsby", "Fitzgerald", nil, {:ok, "9780743273565", %{}})

      TitleSearchCache.await_pending_writes()

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
      TitleSearchCache.await_pending_writes()
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:ok, "9780441172719", %{v: 2}})
      TitleSearchCache.await_pending_writes()

      assert [row] = Repo.all(TitleSearchCacheEntry)
      assert row.metadata["v"] == 2
    end

    test "invalidate_all/0 clears all rows" do
      :ok = TitleSearchCache.put("A", "a", nil, {:ok, "9780000000001", %{}})
      :ok = TitleSearchCache.put("B", "b", nil, {:ok, "9780000000002", %{}})
      TitleSearchCache.await_pending_writes()

      :ok = TitleSearchCache.invalidate_all()

      assert Repo.all(TitleSearchCacheEntry) == []
    end
  end

  describe "invalidate_by_isbn/1 L2" do
    test "deletes matching L2 rows (normalised both sides) and leaves the rest" do
      :ok = TitleSearchCache.put("Crystal City", "Card", nil, {:ok, "978-1-4299-6450-0", %{}})
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:ok, "9780441172719", %{}})
      TitleSearchCache.await_pending_writes()

      :ok = TitleSearchCache.invalidate_by_isbn("9781429964500")

      assert [row] = Repo.all(TitleSearchCacheEntry)
      assert row.isbn == "9780441172719"

      :ets.delete_all_objects(:title_search_cache)
      assert :miss = TitleSearchCache.get("Crystal City", "Card", nil)
      assert {:ok, {:ok, "9780441172719", _}} = TitleSearchCache.get("Dune", "Herbert", nil)
    end

    test "invalidating by ISBN-13 deletes an L2 row stored in ISBN-10 form (and vice versa)" do
      :ok = TitleSearchCache.put("Heartfire", "Card", nil, {:ok, "0312864833", %{}})
      TitleSearchCache.await_pending_writes()

      :ok = TitleSearchCache.invalidate_by_isbn("9780312864835")
      assert Repo.all(TitleSearchCacheEntry) == []

      :ok = TitleSearchCache.put("Heartfire", "Card", nil, {:ok, "9780312864835", %{}})
      TitleSearchCache.await_pending_writes()

      :ok = TitleSearchCache.invalidate_by_isbn("0312864833")
      assert Repo.all(TitleSearchCacheEntry) == []
    end

    test "does not delete negative (not_found) rows" do
      :ok = TitleSearchCache.put("Fake", "Fake", nil, {:error, :not_found})
      TitleSearchCache.await_pending_writes()

      :ok = TitleSearchCache.invalidate_by_isbn("9781429964500")

      assert [row] = Repo.all(TitleSearchCacheEntry)
      assert row.outcome == "not_found"
    end

    test "telemetry count reflects entries removed across both tiers" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "invalidated-l2-test-#{inspect(ref)}",
        [:stacks, :books, :title_search_cache, :invalidated],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:invalidated, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("invalidated-l2-test-#{inspect(ref)}") end)

      :ok = TitleSearchCache.put("Crystal City", "Card", nil, {:ok, "9781429964500", %{}})
      TitleSearchCache.await_pending_writes()

      :ok = TitleSearchCache.invalidate_by_isbn("9781429964500")

      assert_receive {:invalidated, ^ref, %{count: 2}, metadata}
      assert metadata.l1_count == 1
      assert metadata.l2_count == 1
    end
  end
end
