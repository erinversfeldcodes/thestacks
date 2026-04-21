defmodule Stacks.Books.ISBNResolverCache do
  @moduledoc """
  ETS-backed cache for ISBN → book metadata lookups against Open Library
  and Google Books.

  Why cache:
    * ISBN → book metadata is **immutable** once published, so a long TTL is
      safe. Most user uploads are popular titles — the same ISBN gets
      resolved over and over.
    * A cache hit skips two external HTTP round-trips (~400ms+) on the
      upload hot path. Dominates `upload_p95_ms` once warm.

  Cache entry shape:
    `{isbn, result, expires_at_monotonic}` where `result` is one of
    `{:ok, metadata}` or `{:error, :not_found}`.

  TTLs:
    * **Positive** (`{:ok, _}`): 24h. Publisher metadata does drift
      (covers, descriptions) but not fast enough to matter here.
    * **Negative** (`{:error, :not_found}`): 1h. Shorter so a transient
      OL/GB outage that returned `not_found` doesn't poison lookups for
      a whole day once the upstream is healthy again.

  `{:error, :circuit_open}` is **not cached** — the circuit breaker is
  the signal to retry later, not to memoise. Caching it would stall
  resolution until next cleanup sweep even after the fuse resets.

  Mirrors `Stacks.Books.BookDetailCache`'s GenServer + ETS pattern.
  """

  use GenServer

  @table :isbn_resolver_cache
  @positive_ttl_ms 24 * 60 * 60 * 1000
  @negative_ttl_ms 60 * 60 * 1000
  @cleanup_interval 5 * 60 * 1000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Look up a cached ISBN resolution. Returns `{:ok, cached}` where `cached`
  is the memoised `resolve/1` return value, or `:miss` if absent/expired.
  """
  @spec get(String.t()) :: {:ok, {:ok, map()} | {:error, :not_found}} | :miss
  def get(isbn) when is_binary(isbn) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, isbn) do
      [{^isbn, result, expires_at}] when now < expires_at -> {:ok, result}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Store a resolution result. Positive results get a 24h TTL, negative get
  1h. Other terms (e.g. `{:error, :circuit_open}`) are not cached.
  """
  @spec put(String.t(), term()) :: :ok
  def put(isbn, {:ok, _metadata} = result) when is_binary(isbn) do
    insert(isbn, result, @positive_ttl_ms)
  end

  def put(isbn, {:error, :not_found} = result) when is_binary(isbn) do
    insert(isbn, result, @negative_ttl_ms)
  end

  def put(_isbn, _other), do: :ok

  @doc "Remove a single entry. Useful when metadata is refreshed externally."
  @spec invalidate(String.t()) :: :ok
  def invalidate(isbn) when is_binary(isbn) do
    :ets.delete(@table, isbn)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Clear the entire cache."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert(isbn, result, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {isbn, result, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
