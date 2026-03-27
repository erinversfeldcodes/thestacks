defmodule Stacks.CircuitBreakers do
  @moduledoc """
  Installs all Fuse circuit breakers at application startup and provides
  a single shared `melt/1` helper that emits consistent telemetry on every
  state change.

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
    - `[:stacks, :fuse, :melt]`  — circuit is still closed after the melt
    - `[:stacks, :fuse, :blown]` — the melt tipped the circuit open

  Metadata: `%{fuse_name: atom()}`. Measurements: `%{}`.
  """

  use GenServer

  require Logger

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
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    install_all()
    {:ok, %{}}
  end
end
