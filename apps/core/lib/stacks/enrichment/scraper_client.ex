defmodule Stacks.Enrichment.ScraperClient do
  @moduledoc """
  HTTP client for calling the Rust scraper service.

  The actual implementation is swappable via Application env:
    config :core, :scraper_client, Stacks.Enrichment.ScraperClient       # real HTTP
    config :core, :scraper_client, Stacks.Enrichment.MockScraperClient  # tests

  ## Service-to-Service Authentication

  Requests use the same timestamp-based HMAC scheme as the vision service:
    - Header: `X-Internal-Token`
    - Value: `<unix_ts>.<HMAC-SHA256(secret, "<ts>.POST./scrape")>` (hex-encoded)
    - Secret: `SCRAPER_HMAC_SECRET` env var
  """

  @behaviour Stacks.Enrichment.ScraperClientBehaviour

  require Logger

  @impl true
  def scrape(isbn, store_name) do
    case configured_client() do
      __MODULE__ -> do_scrape(isbn, store_name)
      client -> client.scrape(isbn, store_name)
    end
  end

  defp do_scrape(isbn, store_name) do
    base_url = Application.get_env(:core, :scraper_service_url, "http://localhost:8080")
    path = "/scrape"
    url = "#{base_url}#{path}"
    body = Jason.encode!(%{isbn: isbn, store: store_name})
    token = auth_token("POST", path)

    req =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/json"}, {"x-internal-token", token}],
        body
      )

    case Finch.request(req, Stacks.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.warning("ScraperClient: HTTP #{status} for isbn=#{isbn} store=#{store_name}")
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
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
