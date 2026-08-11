defmodule Stacks.Books.TitleSearchCache do
  @moduledoc """
  Two-level cache (ETS + `cache.title_search_cache` Postgres, same shape
  as `ISBNResolverCache`) for the title-search path — the no-barcode route
  that runs up to 12 query variants across OL/GB at ~1–3s per book. Keyed on
  the search signals, not ISBN, which is why it's a separate cache. Stored
  results are only ANSWERS: `{:ok, isbn, metadata}` or `{:error,
  :not_found}` — "we could not look" has no representation here by design.
  """

  use GenServer

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.ISBN
  alias Stacks.Books.ISBNResolverCache
  alias Stacks.Books.TitleSearchCacheEntry

  require Logger

  @table :title_search_cache
  @positive_ttl_ms 24 * 60 * 60 * 1000
  @negative_ttl_ms 60 * 60 * 1000
  @cleanup_interval 5 * 60 * 1000

  @metadata_atom_keys ~w(
    title author description subjects publication_year cover_image_url
    publisher page_count source isbn_10 isbn_13 language
  )a

  @metadata_atom_values %{
    "open_library" => :open_library,
    "google_books" => :google_books
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Look up a cached title-search resolution. Returns `{:ok, cached}` where
  `cached` is the memoised return value of
  `ISBNResolver.search_by_title/3`, or `:miss` if absent/expired in both
  tiers.
  """
  @spec get(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, {:ok, String.t(), map()} | {:error, :not_found}} | :miss
  def get(title, author, raw_text) do
    key = key_for(title, author, raw_text)

    case ets_get(key) do
      {:ok, _} = hit ->
        emit_lookup(:l1, :hit, key)
        hit

      :miss ->
        emit_lookup(:l1, :miss, key)

        case db_get(key) do
          {:ok, _} = hit ->
            emit_lookup(:l2, :hit, key)
            hit

          :miss ->
            emit_lookup(:l2, :miss, key)
            :miss
        end
    end
  end

  @doc """
  Store a title-search resolution. Only ANSWERS are stored: `{:ok, isbn,
  meta}` for 24h; `{:error, :not_found}` for 1h (still a fact about the
  book, but the one most likely to stop being true). `{:error,
  :unavailable}` is named explicitly and NOT stored — memoising a provider
  outage would serve "this book does not exist" to every reader for an hour
  after a 503 (352). Everything else falls to the catch-all and is skipped
  with telemetry.
  """
  @spec put(String.t() | nil, String.t() | nil, String.t() | nil, term()) :: :ok
  def put(title, author, raw_text, {:ok, isbn, metadata} = result)
      when is_binary(isbn) and is_map(metadata) do
    key = key_for(title, author, raw_text)
    ets_put(key, result, @positive_ttl_ms)
    db_put(key, title, author, raw_text, result, @positive_ttl_ms)
    :ok
  end

  def put(title, author, raw_text, {:error, :not_found} = result) do
    key = key_for(title, author, raw_text)
    ets_put(key, result, @negative_ttl_ms)
    db_put(key, title, author, raw_text, result, @negative_ttl_ms)
    :ok
  end

  def put(_title, _author, _raw_text, {:error, :unavailable}), do: :ok

  def put(_title, _author, _raw_text, _other), do: :ok

  @doc "Clear the entire cache (both tiers)."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    ets_delete_all()
    db_delete_all()
    :ok
  end

  @doc """
  Invalidate every entry whose positive result resolved to `isbn` — called
  on rejected identifications, so the bad `(title, author, raw_text) → ISBN`
  memo can't poison round one of the next upload (retry rounds carry
  `excluded_isbns` and bypass the cache; round one doesn't).

  Matching is canonical-ISBN-13 equality on BOTH sides
  (`ISBN.canonical_isbn13/1`): OL docs often memoise an ISBN-10, rejections
  pass the edition's ISBN-13 — bare string equality made this a no-op.
  Cross-edition invalidation is the caller's job (pass every edition ISBN).
  L1 scan-deletes matching entries; L2 deletes rows; both tiers tolerate
  the other failing.
  """
  @spec invalidate_by_isbn(String.t()) :: :ok
  def invalidate_by_isbn(isbn) when is_binary(isbn) do
    case ISBN.canonical_isbn13(isbn) do
      "" ->
        :ok

      canonical ->
        l1_count = ets_delete_by_isbn(canonical)
        l2_count = db_delete_by_isbn(canonical)
        emit_invalidated(canonical, l1_count, l2_count)
        :ok
    end
  end

  def invalidate_by_isbn(_isbn), do: :ok

  @doc """
  Await all in-flight async L2 write tasks from the shared
  `Stacks.Books.CacheWriteSupervisor`. Test-only — tests that assert on
  DB-level effects after a `put/4` must call this first, or the async
  write may not have landed yet. Not part of the production caller
  contract.
  """
  @spec await_pending_writes(timeout()) :: :ok
  def await_pending_writes(timeout \\ 500) do
    ISBNResolverCache.await_pending_writes(timeout)
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

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp ets_get(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, result, expires_at}] when now < expires_at -> {:ok, result}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp ets_put(key, result, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, result, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ets_delete_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ets_delete_by_isbn(canonical_isbn) do
    @table
    |> :ets.tab2list()
    |> Enum.count(fn
      {key, {:ok, stored_isbn, _metadata}, _expires_at} ->
        if ISBN.canonical_isbn13(stored_isbn) == canonical_isbn do
          :ets.delete(@table, key)
          true
        else
          false
        end

      _entry ->
        false
    end)
  rescue
    ArgumentError -> 0
  end

  defp db_get(key) do
    if persistent_enabled?() do
      now = DateTime.utc_now()

      query =
        from(e in TitleSearchCacheEntry,
          where: e.cache_key == ^key and e.expires_at > ^now,
          select: {e.outcome, e.isbn, e.metadata, e.expires_at}
        )

      case Repo.one(query) do
        nil ->
          :miss

        {outcome, isbn, metadata, expires_at} ->
          result = deserialize(outcome, isbn, metadata)
          ttl_ms = max(DateTime.diff(expires_at, now, :millisecond), 0)
          ets_put(key, result, ttl_ms)
          {:ok, result}
      end
    else
      :miss
    end
  rescue
    error ->
      Logger.warning("TitleSearchCache L2 read failed for #{inspect(key)}: #{inspect(error)}")
      :miss
  end

  defp db_put(key, title, author, raw_text, result, ttl_ms) do
    if persistent_enabled?() do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, ttl_ms, :millisecond)
      {outcome, isbn, metadata} = serialize(result)

      attrs = %{
        cache_key: key,
        title: title || "",
        author: author || "",
        raw_text: raw_text || "",
        outcome: outcome,
        isbn: isbn,
        metadata: metadata,
        expires_at: expires_at,
        created_at: now,
        updated_at: now
      }

      async_db_put(key, attrs)
    end

    :ok
  end

  defp async_db_put(key, attrs) do
    Task.Supervisor.start_child(Stacks.Books.CacheWriteSupervisor, fn ->
      try do
        Repo.insert_all(TitleSearchCacheEntry, [attrs],
          on_conflict: {:replace, [:outcome, :isbn, :metadata, :expires_at, :updated_at]},
          conflict_target: :cache_key
        )

        emit_put(:stored, key)
      rescue
        error ->
          Logger.warning(
            "TitleSearchCache L2 write failed for #{inspect(key)}: #{inspect(error)}"
          )

          emit_put(:error, key)
      end
    end)

    :ok
  end

  defp db_delete_all do
    if persistent_enabled?() do
      Repo.delete_all(TitleSearchCacheEntry)
    end

    :ok
  rescue
    error ->
      Logger.warning("TitleSearchCache L2 delete_all failed: #{inspect(error)}")
      :ok
  end

  defp db_delete_by_isbn(canonical_isbn) do
    if persistent_enabled?() do
      matching_ids =
        from(e in TitleSearchCacheEntry,
          where: e.outcome == "found",
          select: {e.id, e.isbn}
        )
        |> Repo.all()
        |> Enum.filter(fn {_id, isbn} -> ISBN.canonical_isbn13(isbn) == canonical_isbn end)
        |> Enum.map(fn {id, _isbn} -> id end)

      case matching_ids do
        [] ->
          0

        ids ->
          {count, _} =
            Repo.delete_all(from(e in TitleSearchCacheEntry, where: e.id in ^ids))

          count
      end
    else
      0
    end
  rescue
    error ->
      Logger.warning(
        "TitleSearchCache L2 delete_by_isbn failed for #{canonical_isbn}: #{inspect(error)}"
      )

      0
  end

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

  defp serialize({:ok, isbn, metadata}) when is_binary(isbn) and is_map(metadata) do
    {"found", isbn, serialize_metadata(metadata)}
  end

  defp serialize({:error, :not_found}), do: {"not_found", "", nil}

  defp serialize_metadata(metadata) do
    Map.new(metadata, fn
      {key, value} when is_atom(key) ->
        {Atom.to_string(key), serialize_value(value)}

      {key, value} when is_binary(key) ->
        {key, serialize_value(value)}
    end)
  end

  defp serialize_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp serialize_value(value), do: value

  defp deserialize("found", isbn, metadata) when is_binary(isbn) do
    {:ok, isbn, deserialize_metadata(metadata || %{})}
  end

  defp deserialize("not_found", _isbn, _metadata), do: {:error, :not_found}

  defp deserialize_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      atom_key = atom_key_for(key)
      Map.put(acc, atom_key, deserialize_value(atom_key, value))
    end)
  end

  defp atom_key_for(key) when is_binary(key) do
    key_atom = Enum.find(@metadata_atom_keys, &(Atom.to_string(&1) == key))
    key_atom || key
  end

  defp atom_key_for(key), do: key

  defp deserialize_value(:source, value) when is_binary(value) do
    Map.get(@metadata_atom_values, value, value)
  end

  defp deserialize_value(_key, value), do: value

  defp persistent_enabled? do
    Application.get_env(:core, :persistent_cache_enabled, true)
  end

  defp emit_lookup(tier, outcome, cache_key) do
    :telemetry.execute(
      [:stacks, :books, :title_search_cache, :lookup],
      %{count: 1},
      %{tier: tier, outcome: outcome, cache_key: cache_key}
    )
  end

  defp emit_put(outcome, cache_key) do
    :telemetry.execute(
      [:stacks, :books, :title_search_cache, :put],
      %{count: 1},
      %{tier: :l2, outcome: outcome, cache_key: cache_key}
    )
  end

  defp emit_invalidated(isbn, l1_count, l2_count) do
    :telemetry.execute(
      [:stacks, :books, :title_search_cache, :invalidated],
      %{count: l1_count + l2_count},
      %{isbn: isbn, l1_count: l1_count, l2_count: l2_count}
    )
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
