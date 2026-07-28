defmodule Stacks.Enrichment.ScraperClient do
  @moduledoc """
  HTTP client for calling the Rust scraper service.

  Wire contract: `proto/stacks/internal/v1/scraper.proto`
  (ScrapeRequest/Response, ConfigReloadResponse)

  The actual implementation is swappable via Application env:
    config :core, :scraper_client, Stacks.Enrichment.ScraperClient       # real HTTP
    config :core, :scraper_client, Stacks.Enrichment.MockScraperClient  # tests

  ## Service-to-Service Authentication

  Requests use the same timestamp-based HMAC scheme as the vision service:
    - Header: `X-Internal-Token`
    - Value: `<unix_ts>.<HMAC-SHA256(secret, "<ts>.POST./scrape")>` (hex-encoded)
    - Secret: `SCRAPER_HMAC_SECRET` env var

  ## Circuit Breakers — two, covering different failure domains

  Both are consulted before a request and either being open yields
  `{:error, :circuit_open}`:

  - **`:scraper_fuse`** — the *sidecar* is unreachable or rejecting us. Shared by
    every store, which is right: if the service is down, no store can be scraped.
    Melted on a transport failure or an HTTP 401.
  - **`:scraper_store_fuse_<store>`** — *this shop* is failing: an upstream HTTP
    error, a rate limit, a missing config, or an extractor that cannot parse its
    pages. Melted on any other non-200, and on a
    `SCRAPE_OUTCOME_EXTRACTOR_FAILED` response.

  The split matters because the shared fuse opens for 15 minutes after 3 failures.
  Previously every failure melted it, so one bad shop stopped price scraping for
  all of them — repeatedly, since most causes recur on every attempt.

  Note what does **not** melt anything: `NOT_STOCKED` and `ROBOTS_BLOCKED` are
  determinations, not failures, and arrive as HTTP 200 (see
  `ScrapeOutcome` in the proto).
  """

  @behaviour Stacks.Enrichment.ScraperClientBehaviour

  alias Stacks.CircuitBreakers
  alias Stacks.Proto.Scraper.ScrapeRequest

  require Logger

  @fuse_name :scraper_fuse

  @impl true
  def scrape(isbn, store_name) do
    case configured_client() do
      __MODULE__ -> do_scrape(isbn, store_name)
      client -> client.scrape(isbn, store_name)
    end
  end

  defp do_scrape(isbn, store_name) do
    store_fuse = CircuitBreakers.store_fuse(store_name)

    # Both domains must be healthy. Asking the service fuse first means a downed
    # sidecar short-circuits without allocating or consulting store state.
    with :ok <- ask(@fuse_name),
         :ok <- ask(store_fuse) do
      make_scraper_request(isbn, store_name, store_fuse)
    end
  end

  defp ask(fuse_name) do
    case :fuse.ask(fuse_name, :sync) do
      :ok -> :ok
      # `:not_found` can only happen if a fuse was never installed — treat it as
      # closed rather than blocking scrapes on a bookkeeping gap.
      {:error, :not_found} -> :ok
      :blown -> {:error, :circuit_open}
    end
  end

  # An HTTP 200 carrying EXTRACTOR_FAILED means the service worked and this store's
  # extraction did not — a per-store fault that should back off from this store
  # alone. NOT_STOCKED and ROBOTS_BLOCKED are determinations and melt nothing.
  defp melt_if_extractor_failed(
         {:ok, %{"outcome" => "SCRAPE_OUTCOME_EXTRACTOR_FAILED"}},
         store_fuse,
         isbn,
         store_name
       ) do
    CircuitBreakers.melt(store_fuse)

    Logger.warning(
      "ScraperClient: extraction failed for isbn=#{isbn} store=#{store_name}; melting #{store_fuse}"
    )

    :ok
  end

  defp melt_if_extractor_failed(_decoded, _store_fuse, _isbn, _store_name), do: :ok

  @impl true
  def build_index(store_name) do
    case configured_client() do
      __MODULE__ -> do_build_index(store_name)
      client -> client.build_index(store_name)
    end
  end

  # Only the service fuse gates this, not the store's. A store fuse opens because
  # *price lookups* are failing there, and rebuilding the index is often the fix — so
  # letting the store's own breaker block the repair would be self-defeating.
  defp do_build_index(store_name) do
    with :ok <- ask(@fuse_name) do
      # Minutes, not seconds: the sweep waits on the shop's rate limit by design.
      index_request(store_name)
      |> Finch.request(Stacks.Finch, receive_timeout: 600_000)
      |> handle_index_response(store_name)
    end
  end

  defp index_request(store_name) do
    path = "/index/build"

    Finch.build(
      :post,
      "#{base_url()}#{path}",
      [{"content-type", "application/json"}, {"X-Internal-Token", auth_token("POST", path)}],
      Jason.encode!(%{isbn: "", store: store_name})
    )
  end

  defp handle_index_response({:ok, %Finch.Response{status: 200, body: body}}, _store_name) do
    case Jason.decode(body) do
      {:ok, %{"entries" => n}} -> {:ok, n}
      _ -> {:error, :unexpected_response}
    end
  end

  defp handle_index_response({:ok, %Finch.Response{status: status, body: body}}, store_name) do
    # Service fuse only: an index build says nothing about one store's prices.
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: index build HTTP #{status} for #{store_name}: #{body}")
    {:error, {:http, status}}
  end

  defp handle_index_response({:error, reason}, store_name) do
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: index build failed for #{store_name}: #{inspect(reason)}")
    {:error, reason}
  end

  defp base_url do
    Application.get_env(:core, :scraper_service_url, "http://localhost:8080")
  end

  defp build_scraper_request(isbn, store_name) do
    path = "/scrape"
    url = "#{base_url()}#{path}"
    body = Jason.encode!(%ScrapeRequest{isbn: isbn, store: store_name})
    token = auth_token("POST", path)

    Finch.build(
      :post,
      url,
      [{"content-type", "application/json"}, {"X-Internal-Token", token}],
      body
    )
  end

  defp make_scraper_request(isbn, store_name, store_fuse) do
    req = build_scraper_request(isbn, store_name)
    # Telemetry :start is emitted here (after fuse gate) so every :start has a
    # matching :stop/:exception — necessary for handlers that track open spans.
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:stacks, :scraper, :request, :start],
      %{system_time: System.system_time()},
      %{isbn: isbn, store: store_name}
    )

    case Finch.request(req, Stacks.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :stop],
          %{duration: duration},
          %{isbn: isbn, store: store_name, status: 200}
        )

        decoded = Jason.decode(resp_body)
        melt_if_extractor_failed(decoded, store_fuse, isbn, store_name)
        decoded

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :stop],
          %{duration: duration},
          %{isbn: isbn, store: store_name, status: status}
        )

        # A 401 means our HMAC is wrong, which is true of every store — that is a
        # service problem. Everything else non-200 is store-specific after the
        # outcome split: an upstream HTTP error, a rate limit, a missing or invalid
        # config for this store. Melting the shared fuse for those is what let one
        # shop stop all twelve.
        CircuitBreakers.melt(if status == 401, do: @fuse_name, else: store_fuse)

        Logger.warning("ScraperClient: HTTP #{status} for isbn=#{isbn} store=#{store_name}")
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :exception],
          %{duration: duration},
          %{isbn: isbn, store: store_name, kind: :error, reason: reason}
        )

        # We never reached the sidecar, so this says nothing about any one store.
        CircuitBreakers.melt(@fuse_name)

        Logger.warning(
          "ScraperClient: request failed for isbn=#{isbn} store=#{store_name}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp auth_token(method, path) do
    ts = System.os_time(:second) |> Integer.to_string()
    secret = Application.fetch_env!(:core, :scraper_hmac_secret)
    message = "#{ts}.#{method}.#{path}"
    sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
    "#{ts}.#{sig}"
  end

  defp configured_client do
    Application.get_env(:core, :scraper_client, __MODULE__)
  end
end
