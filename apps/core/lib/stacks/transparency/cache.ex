defmodule Stacks.Transparency.Cache do
  @moduledoc """
      Short-TTL ETS cache for the transparency live signals.

      Public `/api/transparency/metrics` page-loads must not each fan out to Fly's
      Prometheus. Successful live-signal computations are cached for a short TTL
      (see `Stacks.Transparency`) so bursts of page-loads are served from memory;
      errored computations are NOT cached, so the next request retries (with the
      context serving the last good value stale-on-error where one exists).

      ETS+TTL wrapper rather than Cachex — Cachex is not a dependency; this mirrors
      the pattern in `Stacks.Books.BookDetailCache`.
  """

  use GenServer

  @table :transparency_cache
  @cleanup_interval 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
      Fetch a cached value by key. Returns `{:ok, value}` when a fresh entry exists
      (younger than `ttl_ms`), otherwise `:miss`.
  """
  @spec get(term(), non_neg_integer()) :: {:ok, term()} | :miss
  def get(key, ttl_ms) do
    now = System.monotonic_time(:millisecond)

    case safe_lookup(key) do
      [{^key, value, inserted_at}] when now - inserted_at < ttl_ms -> {:ok, value}
      _ -> :miss
    end
  end

  @doc """
      Fetch the last cached value for `key` regardless of age. Used for
      stale-on-error reads (serve the last good value when a fresh computation
      fails). Returns `{:ok, value}` when any entry exists, otherwise `:miss`.
  """
  @spec get_stale(term()) :: {:ok, term()} | :miss
  def get_stale(key) do
    case safe_lookup(key) do
      [{^key, value, _inserted_at}] -> {:ok, value}
      _ -> :miss
    end
  end

  @doc "Store a value under `key` with the current monotonic timestamp."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    safe_insert({key, value, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Clear the entire cache (used by tests and manual invalidation)."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    if table_exists?(), do: :ets.delete_all_objects(@table)
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
    cutoff = System.monotonic_time(:millisecond) - 600_000

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval)

  defp safe_lookup(key) do
    if table_exists?(), do: :ets.lookup(@table, key), else: []
  rescue
    ArgumentError -> []
  end

  defp safe_insert(tuple) do
    if table_exists?(), do: :ets.insert(@table, tuple)
  rescue
    ArgumentError -> false
  end

  defp table_exists?, do: :ets.whereis(@table) != :undefined
end
