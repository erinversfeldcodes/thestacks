defmodule Stacks.Books.ISBNResolverCacheTest do
  use ExUnit.Case, async: false

  alias Stacks.Books.ISBNResolverCache

  setup do
    # ETS is global — isolate per test by flushing before each.
    ISBNResolverCache.invalidate_all()
    :ok
  end

  describe "get/1 + put/2" do
    test "miss returns :miss for unknown ISBN" do
      assert :miss = ISBNResolverCache.get("9999999999999")
    end

    test "put stores and get returns positive result" do
      meta = %{title: "Gatsby", source: :open_library}
      assert :ok = ISBNResolverCache.put("9780743273565", {:ok, meta})
      assert {:ok, {:ok, ^meta}} = ISBNResolverCache.get("9780743273565")
    end

    test "put stores and get returns negative result" do
      assert :ok = ISBNResolverCache.put("9780000000001", {:error, :not_found})
      assert {:ok, {:error, :not_found}} = ISBNResolverCache.get("9780000000001")
    end

    test "circuit-open results are NOT cached" do
      assert :ok = ISBNResolverCache.put("9780000000002", {:error, :circuit_open})
      assert :miss = ISBNResolverCache.get("9780000000002")
    end

    test "invalidate/1 removes a single entry" do
      ISBNResolverCache.put("9780000000003", {:ok, %{title: "x"}})
      assert {:ok, _} = ISBNResolverCache.get("9780000000003")
      assert :ok = ISBNResolverCache.invalidate("9780000000003")
      assert :miss = ISBNResolverCache.get("9780000000003")
    end

    test "invalidate_all/0 empties the cache" do
      ISBNResolverCache.put("9780000000004", {:ok, %{title: "a"}})
      ISBNResolverCache.put("9780000000005", {:ok, %{title: "b"}})
      assert :ok = ISBNResolverCache.invalidate_all()
      assert :miss = ISBNResolverCache.get("9780000000004")
      assert :miss = ISBNResolverCache.get("9780000000005")
    end
  end
end
