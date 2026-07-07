defmodule Stacks.Books.TitleSearchCache do
  @moduledoc """
  Two-level cache for `Stacks.Books.ISBNResolver.search_by_title/3`.

    * **L1 — ETS** (this GenServer owns the table). Per-node in-memory,
      monotonic-time TTL.
    * **L2 — Postgres** (`cache.title_search_cache`, Ecto schema
      `Stacks.Books.TitleSearchCacheEntry`). Shared across all Fly
      machines; survives machine stops and deploys.

  Why this exists separately from `ISBNResolverCache`:

    * `ISBNResolverCache` keys by ISBN and caches the direct-lookup
      path (`resolve/1`). Books with a clean barcode ISBN hit that
      cache on repeat.
    * The title-search path (no barcode — e.g. screenshot of a book
      cover, screenshot of a text post listing books) does NOT hit
      that cache. It runs up to 12 progressive query variants across
      OpenLibrary and Google Books, costing ~1–3 s per book per
      pipeline. Text-heavy uploads that extract 4–5 books pay that
      per book.

  Cache entry shape (in-memory):
    `{key, result, expires_at_monotonic}` where `result` is either
    `{:ok, isbn, metadata}` or `{:error, :not_found}`.

  Key is a deterministic digest of `(title, author, raw_text)`.
  Normalisation (trim + downcase) collapses whitespace/case variants
  to the same entry.

  TTLs:
    * **Positive** (`{:ok, _, _}`): 24 h.
    * **Negative** (`{:error, :not_found}`): 1 h.

  `{:error, :circuit_open}` is **not cached** — the breaker is the
  signal to retry later, not to memoise.

  Persistence can be disabled per-env via
  `config :core, :persistent_cache_enabled, false` (test env does this).
  """

  use GenServer

  import Ecto.Query

  alias Core.Repo
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

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

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
  Store a title-search resolution. Positive results get 24 h TTL,
  negative 1 h. Other terms (e.g. `{:error, :circuit_open}`) are not
  cached.
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

  def put(_title, _author, _raw_text, _other), do: :ok

  @doc "Clear the entire cache (both tiers)."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    ets_delete_all()
    db_delete_all()
    :ok
  end

  @doc """
  Invalidate every cache entry whose positive result resolved to `isbn`.

  Called when a user rejects an identification: the
  `(title, author, raw_text) → ISBN` memo that produced the wrong pick
  must not survive its 24 h TTL and poison the first round of the next
  upload of the same image (retry rounds carry `excluded_isbns` and
  bypass the cache; round one does not).

  Matching is exact ISBN equality after normalisation — hyphens and
  whitespace stripped, upcased (ISBN-10 check digit `x`) — on BOTH the
  argument and the stored ISBN. No ISBN-10 ↔ ISBN-13 conversion happens
  here; cross-edition invalidation is the caller's job (pass every
  edition ISBN of the rejected book).

  Tier mechanics:

    * **L1 (ETS)** — scan-and-delete: only entries whose stored value is
      `{:ok, matching_isbn, _}` are removed, so the rest of the warm
      cache survives. Per-node only; other Fly machines' L1 entries
      converge when they expire (≤24 h), and cannot be repopulated from
      L2 because the authoritative row is deleted below.
    * **L2 (Postgres)** — a single `DELETE` on `outcome = 'found'` rows
      whose `isbn` column matches after in-SQL normalisation
      (`regexp_replace` + `upper`). Sequential scan is fine at this
      table's scale (bounded by distinct title-search inputs per 24 h).

  Emits `[:stacks, :books, :title_search_cache, :invalidated]` with
  measurements `%{count: n}` (total entries removed across both tiers)
  and metadata `%{isbn: normalised_isbn, l1_count: _, l2_count: _}`.
  """
  @spec invalidate_by_isbn(String.t()) :: :ok
  def invalidate_by_isbn(isbn) when is_binary(isbn) do
    case normalise_isbn(isbn) do
      "" ->
        :ok

      normalised ->
        l1_count = ets_delete_by_isbn(normalised)
        l2_count = db_delete_by_isbn(normalised)
        emit_invalidated(normalised, l1_count, l2_count)
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
  # L1 — ETS helpers
  # ---------------------------------------------------------------------------

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

  # Scan-and-delete L1 entries whose positive result matches the
  # (already normalised) ISBN. Full table scan is acceptable: the table
  # is bounded by distinct title-search inputs within the TTL window,
  # and invalidation only runs on user-initiated rejections.
  defp ets_delete_by_isbn(normalised_isbn) do
    @table
    |> :ets.tab2list()
    |> Enum.count(fn
      {key, {:ok, stored_isbn, _metadata}, _expires_at} ->
        if normalise_isbn(stored_isbn) == normalised_isbn do
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

  # ---------------------------------------------------------------------------
  # L2 — Postgres helpers
  # ---------------------------------------------------------------------------

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

  # Asynchronous L2 upsert — same rationale as
  # `Stacks.Books.ISBNResolverCache.db_put/3`. The upload hot path runs
  # title-search on every non-ISBN candidate (up to 5 per image); paying
  # DB latency on each was the symptom that motivated the L2 cache in the
  # first place. ETS write stays synchronous so the caller's subsequent
  # reads hit the warm local entry; the Postgres upsert is fire-and-forget.
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

  # Delete L2 rows whose stored ISBN matches after in-SQL normalisation
  # (strip hyphens/whitespace, upcase). `outcome = 'found'` rows are the
  # only ones carrying an ISBN; negative rows store "".
  defp db_delete_by_isbn(normalised_isbn) do
    if persistent_enabled?() do
      {count, _} =
        Repo.delete_all(
          from(e in TitleSearchCacheEntry,
            where: e.outcome == "found",
            where:
              fragment(
                "upper(regexp_replace(?, '[\\s-]', '', 'g')) = ?",
                e.isbn,
                ^normalised_isbn
              )
          )
        )

      count
    else
      0
    end
  rescue
    error ->
      Logger.warning(
        "TitleSearchCache L2 delete_by_isbn failed for #{normalised_isbn}: #{inspect(error)}"
      )

      0
  end

  # ---------------------------------------------------------------------------
  # Key / normalisation
  # ---------------------------------------------------------------------------

  # Build the cache key.
  #
  # Algorithm: `normalise(title) <> "\x1f" <> normalise(author) <> "\x1f" <>
  # normalise(raw_text)`, where `normalise/1` trims surrounding whitespace
  # and lowercases. The `\x1f` (ASCII Unit Separator) is used as a field
  # delimiter that cannot appear inside a normalised input.
  #
  # Mirrored in `proto/stacks/infra/v1/book_cache.proto` on
  # `TitleSearchCacheEntry.cache_key`. This algorithm must NOT change
  # without a coordinated migration — every existing persisted row would
  # miss on lookup because the new key wouldn't match the stored digest.
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

  # ISBN normalisation for invalidation matching: strip hyphens and
  # whitespace, upcase (ISBN-10 check digit `x`). Mirrors the in-SQL
  # normalisation in `db_delete_by_isbn/1`.
  defp normalise_isbn(isbn) when is_binary(isbn) do
    isbn
    |> String.replace(~r/[\s-]/, "")
    |> String.upcase()
  end

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

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

  # Emitted from inside the Task.Supervisor fn after the async DB upsert.
  # `outcome` is `:stored` on success, `:error` on a rescued exception.
  # Stacks.Telemetry.Reporter subscribes and writes a `cache_put ...` log
  # line — this is the ONLY way async write failures surface, so the log
  # line must be emitted on every terminal outcome.
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
