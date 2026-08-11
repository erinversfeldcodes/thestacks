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
  | `:brave_fuse`       | Brave Search API       | 5 in 60 s       | 5 min    |
  | `:searxng_fuse`     | SearXNG discovery      | 5 in 60 s       | 5 min    |
  | `:r2_fuse`          | Cloudflare R2 storage  | 5 in 60 s       | 5 min    |

  Plus one fuse **per bookstore** (`:scraper_store_fuse_<store>`, same thresholds as
  `:scraper_fuse`), created on first use via `store_fuse/1`. `:scraper_fuse` covers
  the sidecar being unreachable — genuinely service-wide — while a store fuse
  covers *that shop* failing. Without the split, one bad shop stopped price
  scraping for all twelve, and kept doing so, since most causes recur on every
  attempt. Store fuses are **not probed**: the only way to probe a bookshop is to
  request from it, which is what the open circuit exists to prevent, so they
  recover on the `{:reset, Ms}` backstop.

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

  alias Stacks.Books.ISBNResolver

  @probe_interval_ms 15_000

  @standard_spec {{:standard, 5, 60_000}, {:reset, 300_000}}
  @scraper_spec {{:standard, 3, 60_000}, {:reset, 900_000}}

  @store_spec @scraper_spec

  @max_store_fuses 256

  @store_fuse_prefix "scraper_store_fuse_"

  @fuses [
    vision_fuse: @standard_spec,
    together_ai_fuse: @standard_spec,
    open_library_fuse: @standard_spec,
    google_books_fuse: @standard_spec,
    scraper_fuse: @scraper_spec,
    brave_fuse: @standard_spec,
    searxng_fuse: @standard_spec,
    r2_fuse: @standard_spec,
    nominatim_fuse: @standard_spec
  ]

  @probes %{
    vision_fuse: &__MODULE__.probe_vision/0,
    scraper_fuse: &__MODULE__.probe_scraper/0,
    together_ai_fuse: &__MODULE__.probe_together_ai/0,
    open_library_fuse: &__MODULE__.probe_open_library/0,
    google_books_fuse: &__MODULE__.probe_google_books/0,
    brave_fuse: &__MODULE__.probe_brave/0,
    searxng_fuse: &__MODULE__.probe_searxng/0,
    r2_fuse: &__MODULE__.probe_r2/0
  }

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
  Fuse name for one bookstore's scraper circuit, installed on first use.

  ## Why per-store

  `:scraper_fuse` is shared by every store, and 3 failures open it for 15 minutes.
  With twelve seeded shops that means **one bad shop stops price scraping for all
  of them** — and since most causes recur on every attempt (a hostile site, a
  broken selector, a rate limit), it would keep reopening. Store-scoped circuits
  confine the damage to the store that caused it.

  The two fuses cover different failure domains and both are consulted:

  - `:scraper_fuse` — the sidecar itself is unreachable or rejecting us. Genuinely
    service-wide, so keeping it shared is correct.
  - this fuse — *this shop* is failing: an upstream HTTP error, a rate limit, a
    missing config, or an extractor that cannot parse its pages.

  Returns `:scraper_fuse` if `@max_store_fuses` distinct stores have already been
  seen, so a pathological number of store rows cannot exhaust the atom table.
  """
  @spec store_fuse(String.t() | atom() | nil) :: atom()
  def store_fuse(nil), do: :scraper_fuse

  def store_fuse(store_name) do
    key = store_name |> to_string() |> slugify()

    case fuse_atom(key) do
      nil ->
        :scraper_fuse

      name ->
        ensure_installed(name, @store_spec)
        name
    end
  end

  defp fuse_atom(key) do
    name = @store_fuse_prefix <> key

    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError ->
        if store_fuse_count() < @max_store_fuses do
          String.to_atom(name)
        else
          Logger.warning(
            "CircuitBreakers: #{@max_store_fuses} per-store fuses already allocated; " <>
              "falling back to the shared :scraper_fuse for #{key}"
          )

          nil
        end
    end
  end

  defp store_fuse_count do
    :persistent_term.get({__MODULE__, :store_fuse_count}, 0)
  end

  defp ensure_installed(name, spec) do
    case :fuse.ask(name, :sync) do
      {:error, :not_found} ->
        :fuse.install(name, spec)

        :persistent_term.put(
          {__MODULE__, :store_fuse_count},
          store_fuse_count() + 1
        )

        Logger.debug("CircuitBreakers: installed #{name}")
        :ok

      _ ->
        :ok
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
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
        probe_http_get("https://api.together.xyz/v1/models", [
          {"authorization", "Bearer #{key}"}
        ])

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
  @spec probe_brave() :: :ok | {:error, term()}
  def probe_brave do
    # Probes Brave Search with a lightweight `count=1` query.
    #
    # Probe-auth audit: matches production — the same X-Subscription-Token
    # header production searches send. Requires the API key — without it
    # the fuse can't be meaningfully probed (Brave 401s keyless requests),
    # so we return `{:error, :api_key_not_configured}` and the circuit
    # stays blown until a human rotates the key.
    #
    # One probe call spends ~1 query against the Brave daily budget
    # (67/day on free tier). At the default 15 s probe interval while
    # blown, that's <1% of budget per hour of outage — acceptable.
    case Application.get_env(:core, :brave_search_api_key) do
      key when is_binary(key) and byte_size(key) > 0 ->
        probe_http_get("https://api.search.brave.com/res/v1/web/search?q=test&count=1", [
          {"Accept", "application/json"},
          {"X-Subscription-Token", key}
        ])

      _ ->
        Logger.warning(
          "CircuitBreakers: brave_search_api_key not configured — cannot probe :brave_fuse"
        )

        {:error, :api_key_not_configured}
    end
  end

  @doc false
  @spec probe_searxng() :: :ok | {:error, term()}
  def probe_searxng do
    case Application.get_env(:core, :searxng_url) do
      url when is_binary(url) and byte_size(url) > 0 ->
        probe_http_get(String.trim_trailing(url, "/") <> "/")

      _ ->
        Logger.warning("CircuitBreakers: searxng_url not configured — cannot probe :searxng_fuse")

        {:error, :url_not_configured}
    end
  end

  @doc false
  @spec probe_r2() :: :ok | {:error, term()}
  def probe_r2 do
    case r2_probe_host() do
      host when is_binary(host) and byte_size(host) > 0 ->
        do_probe_r2("https://" <> host <> "/")

      _ ->
        Logger.warning("CircuitBreakers: R2 endpoint not configured — cannot probe :r2_fuse")
        {:error, :endpoint_not_configured}
    end
  end

  defp r2_probe_host do
    case Application.get_env(:core, :r2_endpoint_host) do
      host when is_binary(host) and byte_size(host) > 0 ->
        host

      _ ->
        get_in(Application.get_env(:ex_aws, :s3) || [], [:host])
    end
  end

  defp do_probe_r2(url) do
    case probe_http_client().get(url, []) do
      {:ok, status} when status < 500 -> :ok
      {:ok, status} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec probe_google_books() :: :ok | {:error, term()}
  def probe_google_books do
    probe_http_get(google_books_probe_url())
  end

  @doc false
  # Extracted (and public) so the URL construction is unit-testable without
  # a real HTTP call — see CircuitBreakersTest "probe URL construction".
  #
  # The probe MUST authenticate exactly like production requests do.
  # Keyless Google Books requests always fail: Google's anonymous quota
  # pool returns 429 with `quota_limit_value: "0"` (empirically verified),
  # so an unauthenticated probe can never succeed and probe-based recovery
  # for :google_books_fuse would be structurally impossible — once blown,
  # the fuse stayed blown until the 5-min {:reset, _} backstop and then
  # immediately re-blew under the next burst. We reuse
  # `ISBNResolver.google_books_url/1`, the same builder production search/
  # resolve requests go through, which appends `&key=` when
  # `:google_books_api_key` is configured and omits it otherwise (a nil
  # key means the probe matches whatever production does without a key).
  @spec google_books_probe_url() :: String.t()
  def google_books_probe_url do
    ISBNResolver.google_books_url("q=frankenstein&maxResults=1")
  end

  @impl GenServer
  def init(_opts) do
    install_all()

    :telemetry.detach("stacks-circuit-breakers-probe")

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
      {:noreply, state}
    else
      Process.send_after(self(), {:probe, fuse_name}, @probe_interval_ms)
      {:noreply, %{state | active_probes: MapSet.put(active, fuse_name)}}
    end
  end

  @impl GenServer
  def handle_info({:probe, fuse_name}, %{active_probes: active} = state) do
    state = %{state | active_probes: MapSet.delete(active, fuse_name)}

    case :fuse.ask(fuse_name, :sync) do
      :ok ->
        {:noreply, state}

      _ ->
        {:noreply, do_probe(fuse_name, state)}
    end
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

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

      {:error, :no_probe} ->
        :telemetry.execute(
          [:stacks, :fuse, :probe_failed],
          %{},
          %{fuse_name: fuse_name, reason: :no_probe}
        )

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

  defp run_probe(fuse_name) do
    overrides = Application.get_env(:core, :circuit_breaker_probe_overrides, %{})
    probe_fn = Map.get(overrides, fuse_name) || Map.get(@probes, fuse_name)

    if is_nil(probe_fn) do
      Logger.debug("CircuitBreakers: no probe configured for #{fuse_name}")
      {:error, :no_probe}
    else
      probe_fn.()
    end
  end

  defp probe_http_get(url, headers \\ []) do
    case probe_http_client().get(url, headers) do
      {:ok, 200} -> :ok
      {:ok, status} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe_http_client do
    Application.get_env(
      :core,
      :circuit_breaker_probe_http_client,
      Stacks.CircuitBreakers.ProbeHttpClient
    )
  end
end
