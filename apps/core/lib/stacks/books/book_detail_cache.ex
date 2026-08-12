defmodule Stacks.Books.BookDetailCache do
  @moduledoc """
      ETS-backed cache for book detail lookups.

      Stores `{book_id, data, inserted_at_monotonic}` tuples with a 5-minute TTL.
      A periodic cleanup sweep runs every 60 seconds to evict expired entries.
  """

  use GenServer

  @table :book_detail_cache
  @ttl_ms 300_000
  @cleanup_interval 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
      Look up a cached book detail. Returns `{:ok, data}` or `{:miss, book_id}`.

      Emits `[:stacks,:book_detail_cache,:hit]` on a live hit and
      `[:stacks,:book_detail_cache,:miss]` on a cold lookup or an expired entry
      (expired-as-miss). Telemetry metadata carries `book_id` only — the cache is
      book-keyed and MUST stay free of user identifiers.
  """
  @spec get(binary()) :: {:ok, term()} | {:miss, binary()}
  def get(book_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, book_id) do
      [{^book_id, data, inserted_at}] when now - inserted_at < @ttl_ms ->
        :telemetry.execute([:stacks, :book_detail_cache, :hit], %{count: 1}, %{book_id: book_id})
        {:ok, data}

      _ ->
        :telemetry.execute([:stacks, :book_detail_cache, :miss], %{count: 1}, %{book_id: book_id})
        {:miss, book_id}
    end
  end

  @doc "Store a book detail in the cache."
  @spec put(binary(), term()) :: :ok
  def put(book_id, data) do
    :ets.insert(@table, {book_id, data, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Remove a single book from the cache."
  @spec invalidate(binary()) :: :ok
  def invalidate(book_id) do
    :ets.delete(@table, book_id)
    :ok
  end

  @doc "Clear the entire cache."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @ttl_ms

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
