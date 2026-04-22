defmodule Stacks.Books.TitleSearchCache do
  @moduledoc """
  Two-level cache for `Stacks.Books.ISBNResolver.search_by_title/3`.

    * **L1 — ETS** (this GenServer owns the table). Per-node in-memory,
      monotonic-time TTL.
    * **L2 — Postgres** (`op.title_search_cache`, Ecto schema
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
      {:ok, _} = hit -> hit
      :miss -> db_get(key)
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

      Repo.insert_all(TitleSearchCacheEntry, [attrs],
        on_conflict: {:replace, [:outcome, :isbn, :metadata, :expires_at, :updated_at]},
        conflict_target: :cache_key
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("TitleSearchCache L2 write failed for #{inspect(key)}: #{inspect(error)}")
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

  # ---------------------------------------------------------------------------
  # Key / normalisation
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

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
