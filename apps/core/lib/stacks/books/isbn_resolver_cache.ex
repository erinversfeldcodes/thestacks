defmodule Stacks.Books.ISBNResolverCache do
  @moduledoc """
  Two-level cache for ISBN → book metadata lookups against Open Library
  and Google Books.

    * **L1 — ETS** (this GenServer owns the table). Per-node, in-memory,
      monotonic-time TTL, microsecond reads. The hot path for repeat
      hits within a live node.
    * **L2 — Postgres** (`cache.isbn_resolver_cache`, Ecto schema
      `Stacks.Books.IsbnResolverCacheEntry`). Shared across all Fly
      machines, survives machine stops and deploys, ~1–3 ms round-trip.
      Populated alongside ETS on `put/2`; read on ETS miss and back-fills
      ETS on DB hit.

  Why two layers:

    * ETS alone was ephemeral — `auto_stop_machines = true` on
      `fly.core.toml` means machines idle-stop, wiping the cache.
      Load-balancing across multiple machines also caps per-request hit
      rate at `1 / machine_count` even when cache is warm.
    * Postgres alone would pay the DB round-trip on every hit — fine
      (still beats 400 ms+ OpenLibrary/Google Books calls), but the ETS
      L1 folds it to a pointer chase when a node keeps seeing the same
      ISBNs.

  Cache entry shape (in-memory):
    `{isbn, result, expires_at_monotonic}` where `result` is one of
    `{:ok, metadata}` or `{:error, :not_found}`.

  TTLs:

    * **Positive** (`{:ok, _}`): 24 h. Publisher metadata does drift
      (covers, descriptions) but not fast enough to matter here.
    * **Negative** (`{:error, :not_found}`): 1 h. Shorter so a transient
      OL/GB outage that returned `not_found` doesn't poison lookups for
      a whole day once the upstream is healthy again.

  `{:error, :circuit_open}` is **not cached** — the circuit breaker is
  the signal to retry later, not to memoise. Caching it would stall
  resolution until next cleanup sweep even after the fuse resets.

  Persistence can be disabled per-env via
  `config :core, :persistent_cache_enabled, false` (test env does this —
  see `config/test.exs`). ETS stays on regardless.
  """

  use GenServer

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.IsbnResolverCacheEntry

  require Logger

  @table :isbn_resolver_cache
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
  Look up a cached ISBN resolution. Returns `{:ok, cached}` where `cached`
  is the memoised `resolve/1` return value, or `:miss` if absent/expired
  in both tiers.
  """
  @spec get(String.t()) :: {:ok, {:ok, map()} | {:error, :not_found}} | :miss
  def get(isbn) when is_binary(isbn) do
    case ets_get(isbn) do
      {:ok, _} = hit ->
        emit_lookup(:l1, :hit, isbn)
        hit

      :miss ->
        emit_lookup(:l1, :miss, isbn)

        case db_get(isbn) do
          {:ok, _} = hit ->
            emit_lookup(:l2, :hit, isbn)
            hit

          :miss ->
            emit_lookup(:l2, :miss, isbn)
            :miss
        end
    end
  end

  @doc """
  Store a resolution result.

  Caching policy:

    * `{:ok, _metadata}` → cached for the positive TTL (24 h).
    * `{:error, :not_found}` → cached for the negative TTL (1 h). This is
      the only error worth memoising: a checksum-valid ISBN that genuinely
      isn't in either upstream's catalogue won't suddenly appear within
      the hour.
    * **All other errors are NOT cached** — they signal a transient
      upstream condition (HTTP 429/5xx, transport timeout, malformed JSON,
      blown circuit). Caching any of them poisons subsequent enrichment
      retries for the negative TTL, leaving placeholder titles stuck in
      the UI even after the upstream recovers. We let the fuse + Oban
      retries handle these instead — the upstream is the signal to retry
      later, not to memoise.

  Skips emit `[:stacks, :books, :isbn_resolver_cache, :put_skipped]`
  with `%{isbn: isbn, reason: error_atom}` so the "cache correctly
  refused to poison" path is observable in Fly logs alongside the
  `cache_lookup` and `cache_put` lines.

  Writes to both ETS and Postgres (subject to `:persistent_cache_enabled`).
  """
  @spec put(String.t(), term()) :: :ok
  def put(isbn, {:ok, _metadata} = result) when is_binary(isbn) do
    ets_put(isbn, result, @positive_ttl_ms)
    db_put(isbn, result, @positive_ttl_ms)
    :ok
  end

  def put(isbn, {:error, :not_found} = result) when is_binary(isbn) do
    ets_put(isbn, result, @negative_ttl_ms)
    db_put(isbn, result, @negative_ttl_ms)

    :telemetry.execute(
      [:stacks, :isbn_resolver_cache, :negative_stored],
      %{count: 1, ttl_ms: @negative_ttl_ms},
      %{isbn: isbn}
    )

    :ok
  end

  def put(isbn, {:error, reason})
      when is_binary(isbn) and
             reason in [
               :circuit_open,
               :unexpected_status,
               :timeout,
               :transport_error,
               :malformed_response
             ] do
    :telemetry.execute(
      [:stacks, :books, :isbn_resolver_cache, :put_skipped],
      %{count: 1},
      %{isbn: isbn, reason: reason}
    )

    :ok
  end

  def put(_isbn, _other), do: :ok

  @doc "Remove a single entry from both tiers. Useful when metadata is refreshed externally."
  @spec invalidate(String.t()) :: :ok
  def invalidate(isbn) when is_binary(isbn) do
    ets_delete(isbn)
    db_delete(isbn)
    :ok
  end

  @doc "Clear the entire cache (both tiers)."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    ets_delete_all()
    db_delete_all()
    :ok
  end

  @doc """
  Await all in-flight async L2 write tasks from the shared
  `Stacks.Books.CacheWriteSupervisor`. Test-only — tests that assert on
  DB-level effects after a `put/2` must call this first, or the async
  write may not have landed yet. Not part of the production caller
  contract.

  Important semantics:

    * **Sandbox ownership.** The async task runs in a separate process
      that does NOT inherit the test's Ecto sandbox owner by default.
      Callers must use `Core.DataCase` with `async: false` so the
      sandbox runs in shared mode (`Sandbox.start_owner!(Core.Repo,
      shared: true)`); in shared mode any process on the node can
      transparently use the owner's connection. An `async: true` test
      that fires an async cache write will raise
      `DBConnection.OwnershipError` inside the task.

    * **Snapshot race.** This function calls `Task.Supervisor.children/1`
      once, then monitors the returned PIDs. A task spawned AFTER the
      snapshot is NOT awaited. In practice tests always fire `put` and
      THEN `await_pending_writes`, so the snapshot sees the task — but
      back-to-back `put` + `await` + `put` + assert patterns must call
      `await` a second time before the assertion.

    * **Cross-cache supervisor.** `ISBNResolverCache` and
      `TitleSearchCache` share the same `CacheWriteSupervisor`.
      `await_pending_writes/1` drains BOTH caches' tasks — it is not
      module-scoped. The delegate on `TitleSearchCache.await_pending_writes/1`
      calls this function for the same reason.
  """
  @spec await_pending_writes(timeout()) :: :ok
  def await_pending_writes(timeout \\ 500) do
    Stacks.Books.CacheWriteSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        timeout -> Process.demonitor(ref, [:flush])
      end
    end)

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

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp ets_get(isbn) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, isbn) do
      [{^isbn, result, expires_at}] when now < expires_at -> {:ok, result}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp ets_put(isbn, result, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {isbn, result, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ets_delete(isbn) do
    :ets.delete(@table, isbn)
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

  defp db_get(isbn) do
    if persistent_enabled?() do
      now = DateTime.utc_now()

      query =
        from(e in IsbnResolverCacheEntry,
          where: e.isbn == ^isbn and e.expires_at > ^now,
          select: {e.outcome, e.metadata, e.expires_at}
        )

      case Repo.one(query) do
        nil ->
          :miss

        {outcome, metadata, expires_at} ->
          result = deserialize(outcome, metadata)
          ttl_ms = max(DateTime.diff(expires_at, now, :millisecond), 0)
          ets_put(isbn, result, ttl_ms)
          {:ok, result}
      end
    else
      :miss
    end
  rescue
    error ->
      Logger.warning("ISBNResolverCache L2 read failed for #{inspect(isbn)}: #{inspect(error)}")
      :miss
  end

  defp db_put(isbn, result, ttl_ms) do
    if persistent_enabled?() do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, ttl_ms, :millisecond)
      {outcome, metadata} = serialize(result)

      attrs = %{
        isbn: isbn,
        outcome: outcome,
        metadata: metadata,
        expires_at: expires_at,
        created_at: now,
        updated_at: now
      }

      async_db_put(isbn, attrs)
    end

    :ok
  end

  defp async_db_put(isbn, attrs) do
    Task.Supervisor.start_child(Stacks.Books.CacheWriteSupervisor, fn ->
      try do
        Repo.insert_all(IsbnResolverCacheEntry, [attrs],
          on_conflict: {:replace, [:outcome, :metadata, :expires_at, :updated_at]},
          conflict_target: :isbn
        )

        emit_put(:stored, isbn)
      rescue
        error ->
          Logger.warning(
            "ISBNResolverCache L2 write failed for #{inspect(isbn)}: #{inspect(error)}"
          )

          emit_put(:error, isbn)
      end
    end)

    :ok
  end

  defp db_delete(isbn) do
    if persistent_enabled?() do
      Repo.delete_all(from(e in IsbnResolverCacheEntry, where: e.isbn == ^isbn))
    end

    :ok
  rescue
    error ->
      Logger.warning("ISBNResolverCache L2 delete failed for #{inspect(isbn)}: #{inspect(error)}")
      :ok
  end

  defp db_delete_all do
    if persistent_enabled?() do
      Repo.delete_all(IsbnResolverCacheEntry)
    end

    :ok
  rescue
    error ->
      Logger.warning("ISBNResolverCache L2 delete_all failed: #{inspect(error)}")
      :ok
  end

  defp serialize({:ok, metadata}) when is_map(metadata) do
    {"found", serialize_metadata(metadata)}
  end

  defp serialize({:error, :not_found}), do: {"not_found", nil}

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

  defp deserialize("found", metadata) do
    {:ok, deserialize_metadata(metadata || %{})}
  end

  defp deserialize("not_found", _metadata), do: {:error, :not_found}

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

  defp emit_lookup(tier, outcome, isbn) do
    :telemetry.execute(
      [:stacks, :books, :isbn_resolver_cache, :lookup],
      %{count: 1},
      %{tier: tier, outcome: outcome, isbn: isbn}
    )
  end

  defp emit_put(outcome, isbn) do
    :telemetry.execute(
      [:stacks, :books, :isbn_resolver_cache, :put],
      %{count: 1},
      %{tier: :l2, outcome: outcome, isbn: isbn}
    )
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
