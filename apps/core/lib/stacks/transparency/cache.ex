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

  require Logger

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

  @doc """
      Store a value under `key` with the current monotonic timestamp.

      ⚠️ Reports whether the write landed, and this used to be the one thing it
      could not do. `safe_insert/1` returned a boolean and `put/2` discarded it,
      so a refused write was indistinguishable from a successful one — on a
      cache, that reads as "the page is fast" right up until it isn't, with
      nothing anywhere saying the cache had stopped accepting anything.

      The caller may still ignore the result; a failed cache write is not a
      failed request. What it may no longer do is ignore it *unknowingly*.

      Two failures, told apart on purpose:

      - `:cache_unavailable` — the table is gone, i.e. the owning GenServer is
        restarting. Transient, self-healing, and expected.
      - `:cache_not_writable` — the table EXISTS and refused us. That is a
        configuration defect, not a race: it is what a narrowing of `init/1`'s
        `:public` to `:protected` would produce, because these functions run in
        the calling web-request process and not in the owner. Every write would
        then be refused forever while the page quietly recomputed from Prometheus
        on every load, so this branch is loud.
  """
  @spec put(term(), term()) :: :ok | {:error, :cache_unavailable | :cache_not_writable}
  def put(key, value) do
    case safe_insert({key, value, System.monotonic_time(:millisecond)}) do
      true -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Clear the entire cache (used by tests and manual invalidation)."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
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

  # ⚠️ No `table_exists?()` guard ahead of these, deliberately, and the reason
  # is the invariant.
  #
  # These run in the CALLING process — a web request — not in the GenServer that
  # owns the table. So the owner can die between a `:ets.whereis/1` check and
  # the operation that follows it, and `:ets.lookup/2` takes the table NAME, so
  # it re-resolves and raises. A guard therefore cannot close the window; it can
  # only make the common absent-table case branch instead of raise, which means
  # it is an optimisation and the rescue is the actual mechanism.
  #
  # Keeping both looked like defence in depth and cost more than it bought: two
  # routes to one outcome, of which only the guarded one is reachable from a
  # test. With the guard present, deleting BOTH rescues leaves the suite green
  # — the mechanism that ships was unprovable. With the rescue alone, deleting
  # it fails. Same test, now a guarantee about the code that runs.
  #
  # Cost, stated so nobody has to re-derive it: during a cache outage every read
  # raises and is rescued rather than branching. That window is unreachable at
  # boot — `Stacks.Transparency.Cache` precedes `endpoint_children()` in the
  # supervision list, so no request can arrive before `init/1` creates the table
  # — leaving only a supervisor restart, which is milliseconds and during which
  # every read is already fanning out to Prometheus to recompute. A rescued
  # exception is noise against a cost already being paid.
  #
  # And the accounting is better than "acceptable": measured at 200k iterations,
  # the rescue is ~1.7x FASTER on the present-table path (0.028 vs 0.047 us),
  # because `table_exists?()` was a second name resolution on every hit. The
  # outage-window penalty is ~38ns absolute. So the guard was a per-hit tax to
  # branch on a condition that only occurs during a supervisor restart, and
  # removing it is a net win on the path that runs all the time — not a cost
  # paid for testability, which is how an earlier version of this comment put it.
  # (Single-process microbenchmark on an idle machine; the magnitudes make
  # contention unlikely to flip it, but that was not measured.)
  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp safe_insert(tuple) do
    :ets.insert(@table, tuple)
  rescue
    ArgumentError -> classify_insert_failure()
  end

  # ⚠️ `ArgumentError` from `:ets.insert/2` has two causes and the rescue used to
  # conflate them: the table does not exist, or it exists and this process may
  # not write to it. One is a millisecond-long restart window; the other is
  # permanent and means the cache never caches again.
  #
  # `:ets.whereis/1` separates them after the fact, which is the only place it
  # can be done without reintroducing a check in front of the operation — and a
  # check in front cannot close the race anyway, which is the argument above.
  defp classify_insert_failure do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :cache_unavailable}

      _tid ->
        Logger.error(
          "Transparency.Cache: the cache table exists and REFUSED a write. Every " <>
            "transparency page-load will recompute from Prometheus from now on. This is not " <>
            "the restart race the rescue is for — it is what narrowing the table's :public " <>
            "access would cause, since writes run in the calling request process."
        )

        {:error, :cache_not_writable}
    end
  end
end
