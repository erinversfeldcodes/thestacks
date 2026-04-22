defmodule Stacks.Books.ISBNResolverCachePersistentTest do
  @moduledoc """
  Exercises the Postgres L2 layer of `Stacks.Books.ISBNResolverCache`.

  The default test config sets `:persistent_cache_enabled` to `false` so
  the existing ETS-only unit tests stay deterministic. This file flips
  it on for the duration of each test and uses the Ecto sandbox to roll
  back changes, so neighbouring tests are unaffected.
  """

  use Core.DataCase, async: false

  alias Stacks.Books.ISBNResolverCache
  alias Stacks.Books.IsbnResolverCacheEntry

  setup do
    original = Application.get_env(:core, :persistent_cache_enabled)
    Application.put_env(:core, :persistent_cache_enabled, true)
    on_exit(fn -> Application.put_env(:core, :persistent_cache_enabled, original) end)

    # Clear both tiers so tests can't see leftovers from neighbouring tests.
    ISBNResolverCache.invalidate_all()

    :ok
  end

  describe "L2 persistence" do
    test "put writes a positive result to Postgres" do
      meta = %{title: "Dune", author: "Herbert", source: :open_library}
      :ok = ISBNResolverCache.put("9780441172719", {:ok, meta})

      row = Repo.get_by(IsbnResolverCacheEntry, isbn: "9780441172719")
      assert row.outcome == "found"
      assert row.metadata["title"] == "Dune"
      assert row.metadata["source"] == "open_library"
      assert DateTime.diff(row.expires_at, DateTime.utc_now()) > 23 * 60 * 60
    end

    test "put writes a negative result with 1h TTL" do
      :ok = ISBNResolverCache.put("9999999999999", {:error, :not_found})

      row = Repo.get_by(IsbnResolverCacheEntry, isbn: "9999999999999")
      assert row.outcome == "not_found"
      assert row.metadata == nil
      ttl = DateTime.diff(row.expires_at, DateTime.utc_now())
      assert ttl > 50 * 60
      assert ttl < 65 * 60
    end

    test ":circuit_open is not written to Postgres" do
      :ok = ISBNResolverCache.put("9780441172719", {:error, :circuit_open})
      assert Repo.get_by(IsbnResolverCacheEntry, isbn: "9780441172719") == nil
    end

    test "get falls through to Postgres on ETS miss and returns atom-keyed map" do
      # Seed DB directly, bypassing put/2 (which would also populate ETS).
      now = DateTime.utc_now()

      {1, _} =
        Repo.insert_all(IsbnResolverCacheEntry, [
          %{
            isbn: "9780316556347",
            outcome: "found",
            metadata: %{
              "title" => "Circe",
              "author" => "Madeline Miller",
              "source" => "google_books"
            },
            expires_at: DateTime.add(now, 3600, :second),
            created_at: now,
            updated_at: now
          }
        ])

      # ETS is empty — make sure the L1 rescue path won't hide the L2 behaviour.
      :ets.delete(:isbn_resolver_cache, "9780316556347")

      assert {:ok, {:ok, meta}} = ISBNResolverCache.get("9780316556347")
      assert meta.title == "Circe"
      assert meta.author == "Madeline Miller"
      assert meta.source == :google_books
    end

    test "get populates ETS after an L2 hit so subsequent reads skip the DB" do
      :ok =
        ISBNResolverCache.put("9780316556347", {:ok, %{title: "Circe", source: :google_books}})

      # Wipe ETS but leave the DB row behind.
      :ets.delete_all_objects(:isbn_resolver_cache)

      assert {:ok, {:ok, _}} = ISBNResolverCache.get("9780316556347")

      # ETS should now carry the hydrated entry.
      assert [{_, {:ok, hydrated}, _}] = :ets.lookup(:isbn_resolver_cache, "9780316556347")
      assert hydrated.title == "Circe"
      assert hydrated.source == :google_books
    end

    test "expired rows in Postgres are treated as a miss" do
      now = DateTime.utc_now()

      {1, _} =
        Repo.insert_all(IsbnResolverCacheEntry, [
          %{
            isbn: "9780000000000",
            outcome: "found",
            metadata: %{"title" => "Stale"},
            expires_at: DateTime.add(now, -60, :second),
            created_at: now,
            updated_at: now
          }
        ])

      assert :miss = ISBNResolverCache.get("9780000000000")
    end

    test "put upserts an existing row rather than erroring on the unique index" do
      :ok = ISBNResolverCache.put("9780441172719", {:ok, %{title: "Dune v1"}})
      :ok = ISBNResolverCache.put("9780441172719", {:ok, %{title: "Dune v2"}})

      assert [row] = Repo.all(IsbnResolverCacheEntry)
      assert row.metadata["title"] == "Dune v2"
    end

    test "invalidate/1 removes the row from Postgres" do
      :ok = ISBNResolverCache.put("9780441172719", {:ok, %{title: "Dune"}})
      assert Repo.get_by(IsbnResolverCacheEntry, isbn: "9780441172719")

      :ok = ISBNResolverCache.invalidate("9780441172719")
      assert Repo.get_by(IsbnResolverCacheEntry, isbn: "9780441172719") == nil
    end

    test "invalidate_all/0 clears all rows from Postgres" do
      :ok = ISBNResolverCache.put("9780441172719", {:ok, %{title: "Dune"}})
      :ok = ISBNResolverCache.put("9780316556347", {:ok, %{title: "Circe"}})

      :ok = ISBNResolverCache.invalidate_all()

      assert Repo.all(IsbnResolverCacheEntry) == []
    end
  end
end
