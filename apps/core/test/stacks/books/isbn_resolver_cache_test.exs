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

    test "transient resolver errors are NOT cached and emit :put_skipped" do
      # Subscribe to the put_skipped telemetry event so we can assert the
      # cache emitted the observability signal alongside the no-op.
      handler_id = "test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:stacks, :books, :isbn_resolver_cache, :put_skipped],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:put_skipped, measurements, metadata})
        end,
        nil
      )

      try do
        for reason <- [
              :unexpected_status,
              :timeout,
              :transport_error,
              :malformed_response,
              :circuit_open
            ] do
          isbn = "978000000" <> String.pad_leading(Integer.to_string(:rand.uniform(9999)), 4, "0")
          assert :ok = ISBNResolverCache.put(isbn, {:error, reason})
          assert :miss = ISBNResolverCache.get(isbn)

          assert_receive {:put_skipped, %{count: 1}, %{isbn: ^isbn, reason: ^reason}}, 200
        end
      after
        :telemetry.detach(handler_id)
      end
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
