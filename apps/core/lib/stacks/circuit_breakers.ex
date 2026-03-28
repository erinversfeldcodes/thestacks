defmodule Stacks.CircuitBreakers do
  @moduledoc """
  Installs all Fuse circuit breakers at application startup, emits consistent
  telemetry on every state change, and actively probes blown fuses so that
  circuits close as soon as the underlying service recovers — without waiting
  for the full `{:reset, Ms}` backstop timer.

  ## Managed fuses

  | Fuse name           | Service                | Threshold        | Reset    |
  |---------------------|------------------------|-----------------|----------|
  | `:vision_fuse`      | Modal vision service   | 5 in 60 s       | 5 min    |
  | `:together_ai_fuse` | Together AI LLM API    | 5 in 60 s       | 5 min    |
  | `:open_library_fuse`| Open Library REST API  | 5 in 60 s       | 5 min    |
  | `:google_books_fuse`| Google Books API       | 5 in 60 s       | 5 min    |
  | `:scraper_fuse`     | Rust scraper service   | 3 in 60 s       | 15 min   |

  Per-store fuses are deferred to a follow-on issue.

  ## Telemetry

  Every call to `melt/1` emits one of:
    - `[:stacks, :fuse, :melt]`         — circuit is still closed after the melt
    - `[:stacks, :fuse, :blown]`        — the melt tipped the circuit open

  When a probe runs:
    - `[:stacks, :fuse, :recovered]`    — probe confirmed the service is up;
      circuit has been reset.
      Metadata: `%{fuse_name: atom(), recovered_via: :probe}`.
    - `[:stacks, :fuse, :probe_failed]` — probe attempt failed; next probe
      rescheduled. Metadata: `%{fuse_name: atom(), reason: term()}`.

  All other events: Measurements: `%{}`. Metadata: `%{fuse_name: atom()}`.

  ## Probe-Based Recovery

  When a fuse blows, a `:telemetry` handler attached in `init/1` notifies this
  GenServer, which schedules a `{:probe, fuse_name}` message after
  `@probe_interval_ms` milliseconds. Each probe makes a lightweight HTTP health
  check against the relevant service. On success the circuit is immediately reset;
  on failure a `[:stacks, :fuse, :probe_failed]` event is emitted and the next
  probe is rescheduled.

  Duplicate probe loops are prevented: if a fuse blows multiple times while a
  probe is already active for it (e.g. concurrent melts at the threshold), the
  second `blown` event is a no-op — the GenServer tracks active probes in state
  and only schedules one per fuse at a time.

  The existing `{:reset, Ms}` timer remains as a backstop — if the service
  never recovers, the circuit reopens after the configured window.
  """

  use GenServer

  require Logger

  # How often to probe a blown fuse.
  # {reset, Ms} in each fuse spec is the backstop maximum.
  @probe_interval_ms 15_000

  # 5 failures in 60 s → open for 5 min
  @standard_spec {{:standard, 5, 60_000}, {:reset, 300_000}}
  # 3 failures in 60 s → open for 15 min (scraper is slower to recover)
  @scraper_spec {{:standard, 3, 60_000}, {:reset, 900_000}}

  @fuses [
    vision_fuse: @standard_spec,
    together_ai_fuse: @standard_spec,
    open_library_fuse: @standard_spec,
    google_books_fuse: @standard_spec,
    scraper_fuse: @scraper_spec
  ]

  # Probe functions keyed by fuse atom.
  # Each returns :ok or {:error, reason}.
  # Overrides can be injected via Application env key :circuit_breaker_probe_overrides
  # (used in tests to avoid real HTTP calls).
  @probes %{
    vision_fuse: &__MODULE__.probe_vision/0,
    scraper_fuse: &__MODULE__.probe_scraper/0,
    together_ai_fuse: &__MODULE__.probe_together_ai/0,
    open_library_fuse: &__MODULE__.probe_open_library/0,
    google_books_fuse: &__MODULE__.probe_google_books/0
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the circuit breaker installer as a supervised process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Install all managed fuses. Safe to call multiple times — already-installed
  fuses are skipped without error.

  Returns `:ok`.
  """
  @spec install_all() :: :ok
  def install_all do
    Enum.each(@fuses, fn {name, spec} ->
      case :fuse.ask(name, :sync) do
        {:error, :not_found} ->
          :fuse.install(name, spec)
          Logger.debug("CircuitBreakers: installed #{name}")

        _ ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Melt `fuse_name` and emit telemetry reflecting the resulting circuit state.

  Emits `[:stacks, :fuse, :blown]` if the circuit opened, or
  `[:stacks, :fuse, :melt]` if it is still closed.
  """
  @spec melt(atom()) :: :ok
  def melt(fuse_name) do
    :fuse.melt(fuse_name)

    case :fuse.ask(fuse_name, :sync) do
      :blown ->
        :telemetry.execute([:stacks, :fuse, :blown], %{}, %{fuse_name: fuse_name})

      _ ->
        :telemetry.execute([:stacks, :fuse, :melt], %{}, %{fuse_name: fuse_name})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Probe functions (called by handle_info — public so @probes map can ref them)
  # ---------------------------------------------------------------------------

  @doc false
  @spec probe_vision() :: :ok | {:error, term()}
  def probe_vision do
    base_url = Application.get_env(:core, :vision_service_url, "http://localhost:8000")
    probe_http_get("#{base_url}/health")
  end

  @doc false
  @spec probe_scraper() :: :ok | {:error, term()}
  def probe_scraper do
    base_url = Application.get_env(:core, :scraper_service_url, "http://localhost:8080")
    probe_http_get("#{base_url}/health")
  end

  @doc false
  @spec probe_together_ai() :: :ok | {:error, term()}
  def probe_together_ai do
    case Application.get_env(:core, :vision_together_api_key) do
      key when is_binary(key) and byte_size(key) > 0 ->
        req =
          Finch.build(
            :get,
            "https://api.together.xyz/v1/models",
            [{"authorization", "Bearer #{key}"}],
            nil
          )

        case Finch.request(req, Stacks.Finch, receive_timeout: 5_000) do
          {:ok, %Finch.Response{status: 200}} -> :ok
          {:ok, %Finch.Response{status: status}} -> {:error, {:http_status, status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        Logger.warning(
          "CircuitBreakers: vision_together_api_key not configured — cannot probe :together_ai_fuse"
        )

        {:error, :api_key_not_configured}
    end
  end

  @doc false
  @spec probe_open_library() :: :ok | {:error, term()}
  def probe_open_library do
    probe_http_get("https://openlibrary.org/search.json?q=frankenstein&limit=1")
  end

  @doc false
  @spec probe_google_books() :: :ok | {:error, term()}
  def probe_google_books do
    probe_http_get("https://www.googleapis.com/books/v1/volumes?q=frankenstein&maxResults=1")
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    install_all()

    # Detach first so that a crash+restart does not leave the old handler pointing
    # at the dead PID. :telemetry.detach/1 is a no-op if the handler is not attached.
    :telemetry.detach("stacks-circuit-breakers-probe")

    # Stable handler ID — prevents duplicate handlers from accumulating.
    :telemetry.attach(
      "stacks-circuit-breakers-probe",
      [:stacks, :fuse, :blown],
      &__MODULE__.handle_blown_telemetry/4,
      %{target: self()}
    )

    {:ok, %{active_probes: MapSet.new()}}
  end

  @doc false
  def handle_blown_telemetry(_event, _measurements, %{fuse_name: fuse_name}, %{target: pid}) do
    send(pid, {:maybe_schedule_probe, fuse_name})
  end

  @impl GenServer
  def handle_info({:maybe_schedule_probe, fuse_name}, %{active_probes: active} = state) do
    if MapSet.member?(active, fuse_name) do
      # Probe loop already running for this fuse — duplicate blown event, ignore.
      {:noreply, state}
    else
      Process.send_after(self(), {:probe, fuse_name}, @probe_interval_ms)
      {:noreply, %{state | active_probes: MapSet.put(active, fuse_name)}}
    end
  end

  @impl GenServer
  def handle_info({:probe, fuse_name}, %{active_probes: active} = state) do
    # Remove from the active set before running so the entry is clean
    # regardless of whether the probe succeeds, fails, or is a no-op.
    state = %{state | active_probes: MapSet.delete(active, fuse_name)}

    case :fuse.ask(fuse_name, :sync) do
      :ok ->
        # Backstop timer fired first — circuit already reset, nothing to do.
        {:noreply, state}

      _ ->
        {:noreply, do_probe(fuse_name, state)}
    end
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_probe(fuse_name, state) do
    case run_probe(fuse_name) do
      :ok ->
        :fuse.reset(fuse_name)

        :telemetry.execute(
          [:stacks, :fuse, :recovered],
          %{},
          %{fuse_name: fuse_name, recovered_via: :probe}
        )

        Logger.info("CircuitBreakers: #{fuse_name} recovered via probe")
        state

      {:error, reason} ->
        :telemetry.execute(
          [:stacks, :fuse, :probe_failed],
          %{},
          %{fuse_name: fuse_name, reason: reason}
        )

        Logger.debug(
          "CircuitBreakers: probe for #{fuse_name} failed (#{inspect(reason)}), rescheduling"
        )

        Process.send_after(self(), {:probe, fuse_name}, @probe_interval_ms)
        %{state | active_probes: MapSet.put(state.active_probes, fuse_name)}
    end
  end

  # Run the probe for `fuse_name`, honouring any test overrides.
  defp run_probe(fuse_name) do
    overrides = Application.get_env(:core, :circuit_breaker_probe_overrides, %{})
    probe_fn = Map.get(overrides, fuse_name) || Map.get(@probes, fuse_name)

    if is_nil(probe_fn) do
      Logger.warning("CircuitBreakers: no probe configured for #{fuse_name}")
      {:error, :no_probe}
    else
      probe_fn.()
    end
  end

  defp probe_http_get(url) do
    req = Finch.build(:get, url, [], nil)

    case Finch.request(req, Stacks.Finch, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200}} -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
