defmodule Stacks.Books.BookDetailCacheTelemetryTest do
  @moduledoc """
    Telemetry firing tests for `Stacks.Books.BookDetailCache`.

    Verifies that `get/1` emits `[:stacks,:book_detail_cache,:hit]` on a cache
    hit and `[:stacks,:book_detail_cache,:miss]` on a cold lookup and on an
    expired entry (expired-as-miss). These events feed the cache hit-rate metric.

    GDPR: the cache is book-keyed. Telemetry metadata carries `book_id` ONLY —
    never a user identifier — and this is pinned by the "GDPR" test below.
  """

  use ExUnit.Case, async: false

  alias Stacks.Books.BookDetailCache

  @miss [:stacks, :book_detail_cache, :miss]
  @hit [:stacks, :book_detail_cache, :hit]

  defp attach(event_name) do
    test_pid = self()
    handler_id = "test-#{Enum.join(event_name, "-")}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  setup do
    book_id = Ecto.UUID.generate()
    BookDetailCache.invalidate(book_id)
    on_exit(fn -> BookDetailCache.invalidate(book_id) end)
    {:ok, book_id: book_id}
  end

  describe "get/1 telemetry" do
    test "emits :miss on a cold lookup, metadata carries the book_id", %{book_id: book_id} do
      attach(@miss)

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :miss], %{count: 1}, metadata},
                     1_000

      assert metadata.book_id == book_id
    end

    test "emits :hit after a put, metadata carries the book_id", %{book_id: book_id} do
      attach(@hit)
      BookDetailCache.put(book_id, %{title: "Middlemarch"})

      assert {:ok, %{title: "Middlemarch"}} = BookDetailCache.get(book_id)

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :hit], %{count: 1}, metadata},
                     1_000

      assert metadata.book_id == book_id
    end

    test "emits :miss for an entry past its TTL (expired-as-miss)", %{book_id: book_id} do
      attach(@miss)

      stale = System.monotonic_time(:millisecond) - 400_000
      :ets.insert(:book_detail_cache, {book_id, %{title: "stale"}, stale})

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :miss], %{count: 1}, metadata},
                     1_000

      assert metadata.book_id == book_id
    end

    test "a cold-then-warm read fires :miss then :hit in order", %{book_id: book_id} do
      attach(@miss)
      attach(@hit)

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
      BookDetailCache.put(book_id, %{title: "warm"})
      assert {:ok, _} = BookDetailCache.get(book_id)

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :miss], %{count: 1}, _}, 1_000
      assert_receive {:telemetry, [:stacks, :book_detail_cache, :hit], %{count: 1}, _}, 1_000
    end

    test "GDPR: metadata carries only :book_id — no user identifiers", %{book_id: book_id} do
      attach(@miss)
      attach(@hit)

      BookDetailCache.get(book_id)
      BookDetailCache.put(book_id, %{title: "x"})
      BookDetailCache.get(book_id)

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :miss], _, miss_meta}, 1_000
      assert_receive {:telemetry, [:stacks, :book_detail_cache, :hit], _, hit_meta}, 1_000

      assert Map.keys(miss_meta) == [:book_id]
      assert Map.keys(hit_meta) == [:book_id]
    end
  end
end
