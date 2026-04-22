defmodule Stacks.Books.TitleSearchCache do
  @moduledoc """
  ETS-backed cache for `Stacks.Books.ISBNResolver.search_by_title/3`.

  Why this exists separately from `ISBNResolverCache`:

    * `ISBNResolverCache` keys by ISBN and caches the direct-lookup
      path (`resolve/1`). Books with a clean barcode ISBN hit that
      cache on repeat.
    * The title-search path (no barcode — e.g. screenshot of a book
      cover, screenshot of a text post listing books) does NOT hit
      that cache. It runs up to 12 progressive query variants across
      OpenLibrary and Google Books, costing ~1–3 seconds per book per
      pipeline. Text-heavy uploads that extract 4–5 books pay that
      per book.

  Cache entry shape:
    `{key, result, expires_at_monotonic}` where `result` is either
    `{:ok, isbn, metadata}` or `{:error, :not_found}`.

  Key is a deterministic digest of `(title, author, raw_text)` — the
  same three inputs `search_by_title/3` takes. Normalisation trims
  whitespace and lowercases so slight whitespace/case variation
  between calls doesn't cause false misses.

  TTLs:
    * **Positive** (`{:ok, _, _}`): 24h. An extracted title + author
      reliably maps to the same ISBN; once resolved, the book's
      identity doesn't change.
    * **Negative** (`{:error, :not_found}`): 1h. Shorter so a Google
      Books outage that returned `:not_found` doesn't poison lookups
      for a whole day.

  Mirrors `Stacks.Books.ISBNResolverCache`'s GenServer + ETS pattern.
  """

  use GenServer

  @table :title_search_cache
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
  Look up a cached title-search resolution. Returns `{:ok, cached}`
  where `cached` is the memoised return value of
  `ISBNResolver.search_by_title/3`, or `:miss` if absent/expired.
  """
  @spec get(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, {:ok, String.t(), map()} | {:error, :not_found}} | :miss
  def get(title, author, raw_text) do
    key = key_for(title, author, raw_text)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, result, expires_at}] when now < expires_at -> {:ok, result}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Store a title-search resolution. Positive results get a 24h TTL,
  negative get 1h. Other terms (e.g. `{:error, :circuit_open}`) are
  not cached — the circuit breaker is the signal to retry later, not
  to memoise.
  """
  @spec put(String.t() | nil, String.t() | nil, String.t() | nil, term()) :: :ok
  def put(title, author, raw_text, {:ok, isbn, metadata} = result)
      when is_binary(isbn) and is_map(metadata) do
    insert(key_for(title, author, raw_text), result, @positive_ttl_ms)
  end

  def put(title, author, raw_text, {:error, :not_found} = result) do
    insert(key_for(title, author, raw_text), result, @negative_ttl_ms)
  end

  def put(_title, _author, _raw_text, _other), do: :ok

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

  defp key_for(title, author, raw_text) do
    [title, author, raw_text]
    |> Enum.map_join("\x1f", &normalise/1)
  end

  defp normalise(nil), do: ""
  defp normalise(""), do: ""

  defp normalise(str) when is_binary(str) do
    str
    |> String.trim()
    |> String.downcase()
  end

  defp insert(key, result, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, result, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
