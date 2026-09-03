defmodule Stacks.CircuitBreakers do
  @moduledoc """
      Installs all Fuse circuit breakers at startup, emits telemetry on every
      state change, and actively probes blown fuses so circuits close as soon
      as the service recovers (instead of waiting out the full reset timer).

      Fuses: `:vision_fuse`, `:together_ai_fuse`, `:open_library_fuse`,
      `:google_books_fuse`, `:brave_fuse`, `:searxng_fuse`, `:r2_fuse`,
      `:nominatim_fuse`, `:neon_fuse`, `:resend_fuse`
      (5 failures/60s, 5min reset) and `:scraper_fuse` (3/60s, 15min).
      Per-store scraper fuses are installed lazily via `store_fuse/1`.

      `:neon_fuse` is special: most fuses melt only under real traffic, but
      the database going away must be visible even when nobody is using the
      app — `CoreWeb.Telemetry.poll_db_watchdog/0` pings it every poll tick
      and melts this fuse on failure, so the fuse-state gauge (and the public
      "circuit breakers healthy" signal derived from it) goes to 0 within
      about a minute of a database outage.
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
    nominatim_fuse: @standard_spec,
    neon_fuse: @standard_spec,
    resend_fuse: @standard_spec,
    log_shipper_fuse: @standard_spec
  ]

  @probes %{
    vision_fuse: &__MODULE__.probe_vision/0,
    scraper_fuse: &__MODULE__.probe_scraper/0,
    together_ai_fuse: &__MODULE__.probe_together_ai/0,
    open_library_fuse: &__MODULE__.probe_open_library/0,
    google_books_fuse: &__MODULE__.probe_google_books/0,
    brave_fuse: &__MODULE__.probe_brave/0,
    searxng_fuse: &__MODULE__.probe_searxng/0,
    r2_fuse: &__MODULE__.probe_r2/0,
    nominatim_fuse: &__MODULE__.probe_nominatim/0,
    neon_fuse: &__MODULE__.probe_neon/0,
    resend_fuse: &__MODULE__.probe_resend/0,
    log_shipper_fuse: &__MODULE__.probe_log_shipper/0
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
      Fuse name for ONE bookstore's scraper circuit, installed on first use.
      The shared `:scraper_fuse` covers the sidecar being down (service-wide);
      this one confines a single hostile/broken shop, whose failures recur on
      every attempt and would otherwise keep the shared fuse open for everyone.
      Both are consulted. Falls back to `:scraper_fuse` past `@max_store_fuses`
      distinct stores so store rows cannot exhaust the atom table.
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

      Emits `[:stacks,:fuse,:blown]` if the circuit opened, or
      `[:stacks,:fuse,:melt]` if it is still closed.
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
  @spec probe_nominatim() :: :ok | {:error, term()}
  def probe_nominatim do
    probe_http_get("https://nominatim.openstreetmap.org/status")
  end

  @doc false
  # The one non-HTTP probe: a SELECT 1 through the app's own pool, so the
  # probe exercises exactly the path production queries take.
  @spec probe_neon() :: :ok | {:error, term()}
  def probe_neon do
    case Core.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  # Probe-auth audit: matches production — the same bearer key the Swoosh
  # Resend adapter sends. Without it the fuse can't be meaningfully probed
  # (Resend 401s keyless requests).
  @spec probe_resend() :: :ok | {:error, term()}
  def probe_resend do
    case resend_api_key() do
      key when is_binary(key) and byte_size(key) > 0 ->
        probe_http_get("https://api.resend.com/domains", [
          {"authorization", "Bearer #{key}"}
        ])

      _ ->
        Logger.warning(
          "CircuitBreakers: Resend api_key not configured — cannot probe :resend_fuse"
        )

        {:error, :api_key_not_configured}
    end
  end

  @doc false
  # Same endpoint the telemetry keepalive pings; the keepalive melts this
  # fuse on failure (log-shipper analogue of the neon watchdog).
  @spec probe_log_shipper() :: :ok | {:error, term()}
  def probe_log_shipper do
    case Application.get_env(:core, :log_shipper_keepalive_url) do
      url when is_binary(url) and url != "" ->
        probe_http_get(url <> "/health")

      _ ->
        {:error, :url_not_configured}
    end
  end

  defp resend_api_key do
    :core
    |> Application.get_env(Stacks.Email.Mailer, [])
    |> Keyword.get(:api_key)
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
