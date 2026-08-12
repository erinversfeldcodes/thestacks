defmodule Stacks.Books.TitleSearchCacheTest do
  use ExUnit.Case, async: false

  alias Stacks.Books.TitleSearchCache

  setup do
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

    test "an :unavailable outage is NOT cached" do
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:error, :unavailable})
      assert :miss = TitleSearchCache.get("Dune", "Herbert", nil)
    end

    test "an :unavailable does not overwrite an existing genuine :not_found" do
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:error, :not_found})
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:error, :unavailable})

      assert {:ok, {:error, :not_found}} = TitleSearchCache.get("Dune", "Herbert", nil)
    end

    test "an :unavailable does not overwrite an existing positive result" do
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:ok, "9780441172719", %{}})
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:error, :unavailable})

      assert {:ok, {:ok, "9780441172719", _}} = TitleSearchCache.get("Dune", "Herbert", nil)
    end

    test "whitespace and case variations collapse to the same cache entry" do
      :ok =
        TitleSearchCache.put(
          "The Great Gatsby",
          "F. Scott Fitzgerald",
          nil,
          {:ok, "9780743273565", %{}}
        )

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

  describe "invalidate_by_isbn/1" do
    test "removes every entry whose positive result matches the ISBN, keeps the rest" do
      :ok = TitleSearchCache.put("Crystal City", "Card", nil, {:ok, "9781429964500", %{}})
      :ok = TitleSearchCache.put("Crystal City", "Card", "text hint", {:ok, "9781429964500", %{}})
      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:ok, "9780441172719", %{}})

      :ok = TitleSearchCache.invalidate_by_isbn("9781429964500")

      assert :miss = TitleSearchCache.get("Crystal City", "Card", nil)
      assert :miss = TitleSearchCache.get("Crystal City", "Card", "text hint")
      assert {:ok, {:ok, "9780441172719", _}} = TitleSearchCache.get("Dune", "Herbert", nil)
    end

    test "normalises hyphens/whitespace on both the argument and the stored ISBN" do
      :ok = TitleSearchCache.put("A", "a", nil, {:ok, "978-1-4299-6450-0", %{}})
      :ok = TitleSearchCache.invalidate_by_isbn("9781429964500")
      assert :miss = TitleSearchCache.get("A", "a", nil)

      :ok = TitleSearchCache.put("B", "b", nil, {:ok, "9781429964500", %{}})
      :ok = TitleSearchCache.invalidate_by_isbn(" 978-1-4299-6450-0 ")
      assert :miss = TitleSearchCache.get("B", "b", nil)
    end

    test "invalidating by ISBN-13 removes an entry stored in ISBN-10 form" do
      :ok = TitleSearchCache.put("Heartfire", "Card", nil, {:ok, "0312864833", %{}})
      :ok = TitleSearchCache.invalidate_by_isbn("9780312864835")
      assert :miss = TitleSearchCache.get("Heartfire", "Card", nil)
    end

    test "invalidating by ISBN-10 removes an entry stored in ISBN-13 form" do
      :ok = TitleSearchCache.put("Heartfire", "Card", nil, {:ok, "9780312864835", %{}})
      :ok = TitleSearchCache.invalidate_by_isbn("0312864833")
      assert :miss = TitleSearchCache.get("Heartfire", "Card", nil)
    end

    test "cross-form invalidation handles an ISBN-10 with X check digit" do
      :ok = TitleSearchCache.put("Obasan", "Kogawa", nil, {:ok, "080442957X", %{}})
      :ok = TitleSearchCache.invalidate_by_isbn("9780804429573")
      assert :miss = TitleSearchCache.get("Obasan", "Kogawa", nil)
    end

    test "does not remove negative entries or entries for other ISBNs" do
      :ok = TitleSearchCache.put("Fake", "Fake", nil, {:error, :not_found})
      :ok = TitleSearchCache.invalidate_by_isbn("9781429964500")
      assert {:ok, {:error, :not_found}} = TitleSearchCache.get("Fake", "Fake", nil)
    end

    test "blank or non-binary ISBNs are a no-op" do
      :ok = TitleSearchCache.put("A", "a", nil, {:ok, "9780000000001", %{}})
      assert :ok = TitleSearchCache.invalidate_by_isbn("")
      assert :ok = TitleSearchCache.invalidate_by_isbn("  - ")
      assert :ok = TitleSearchCache.invalidate_by_isbn(nil)
      assert {:ok, {:ok, "9780000000001", _}} = TitleSearchCache.get("A", "a", nil)
    end

    test "emits [:stacks, :books, :title_search_cache, :invalidated] telemetry with count" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "invalidated-test-#{inspect(ref)}",
        [:stacks, :books, :title_search_cache, :invalidated],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:invalidated, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("invalidated-test-#{inspect(ref)}") end)

      :ok = TitleSearchCache.put("Crystal City", "Card", nil, {:ok, "9781429964500", %{}})
      :ok = TitleSearchCache.invalidate_by_isbn("978-1-4299-6450-0")

      assert_receive {:invalidated, ^ref, %{count: 1}, metadata}
      assert metadata.isbn == "9781429964500"
      assert metadata.l1_count == 1
      assert metadata.l2_count == 0
    end
  end
end
