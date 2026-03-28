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

  ## Circuit Breaker

  Protected by `:scraper_fuse` — managed by `Stacks.CircuitBreakers`.
  When blown, `scrape/2` returns `{:error, :circuit_open}`.
  """

  @behaviour Stacks.Enrichment.ScraperClientBehaviour

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
    case :fuse.ask(@fuse_name, :sync) do
      :ok -> make_scraper_request(isbn, store_name)
      :blown -> {:error, :circuit_open}
    end
  end

  defp build_scraper_request(isbn, store_name) do
    base_url = Application.get_env(:core, :scraper_service_url, "http://localhost:8080")
    path = "/scrape"
    url = "#{base_url}#{path}"
    body = Jason.encode!(%ScrapeRequest{isbn: isbn, store: store_name})
    token = auth_token("POST", path)

    Finch.build(
      :post,
      url,
      [{"content-type", "application/json"}, {"X-Internal-Token", token}],
      body
    )
  end

  defp make_scraper_request(isbn, store_name) do
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

        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :stop],
          %{duration: duration},
          %{isbn: isbn, store: store_name, status: status}
        )

        Stacks.CircuitBreakers.melt(@fuse_name)
        Logger.warning("ScraperClient: HTTP #{status} for isbn=#{isbn} store=#{store_name}")
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :exception],
          %{duration: duration},
          %{isbn: isbn, store: store_name, kind: :error, reason: reason}
        )

        Stacks.CircuitBreakers.melt(@fuse_name)

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
