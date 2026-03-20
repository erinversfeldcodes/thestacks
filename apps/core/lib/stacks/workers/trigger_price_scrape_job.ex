defmodule Stacks.Workers.TriggerPriceScrapeJob do
  @moduledoc """
  Oban worker that triggers price scraping for a book's ISBN across bookstores.

  ## Modes

  - **Single ISBN:** `%{isbn: "978...", book_id: "uuid"}` — scrapes this ISBN
    at all stores.
  - **Batch:** `%{batch: true}` — finds all stale ISBNs and scrapes them.

  Results are pushed to `PricePipeline` (Broadway) for batched persistence.
  A Fuse circuit breaker (`:scraper_fuse`) protects against scraper downtime.
  """

  use Oban.Worker, queue: :scraper, max_attempts: 3

  require Logger

  alias Stacks.Enrichment.PricePipeline
  alias Stacks.Enrichment.Prices
  alias Stacks.Monitoring

  @fuse_name :scraper_fuse

  @impl true
  def perform(%Oban.Job{args: %{"batch" => true}}) do
    Logger.info("TriggerPriceScrapeJob: starting batch scrape")
    stale = Prices.stale_isbns(7)
    stores = Prices.all_stores()

    if Enum.empty?(stale) or Enum.empty?(stores) do
      Logger.info(
        "TriggerPriceScrapeJob: nothing to scrape (stale=#{length(stale)} stores=#{length(stores)})"
      )

      :ok
    else
      scrape_all(stale, stores)
    end
  end

  def perform(%Oban.Job{args: %{"isbn" => isbn, "book_id" => book_id}}) do
    Logger.info("TriggerPriceScrapeJob: scraping isbn=#{isbn}")
    stores = Prices.all_stores()

    if Enum.empty?(stores) do
      Logger.info("TriggerPriceScrapeJob: no stores configured, skipping")
      :ok
    else
      scrape_all([%{isbn: isbn, book_id: book_id}], stores)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("TriggerPriceScrapeJob: unrecognized args: #{inspect(args)}")
    :ok
  end

  defp scrape_all(isbn_entries, stores) do
    case :fuse.ask(@fuse_name, :sync) do
      :blown ->
        Logger.warning("TriggerPriceScrapeJob: circuit breaker open, skipping scrape")
        {:error, :circuit_open}

      fuse_result when fuse_result in [:ok, {:error, :not_found}] ->
        results = do_scrape_all(isbn_entries, stores)
        push_successful_results(results)
        evaluate_outcome(results)
    end
  end

  defp push_successful_results(results) do
    messages =
      Enum.flat_map(results, fn
        {:ok, data} ->
          [%Broadway.Message{data: data, acknowledger: Broadway.NoopAcknowledger.init()}]

        _ ->
          []
      end)

    unless messages == [] do
      Broadway.push_messages(PricePipeline, messages)
    end
  end

  defp evaluate_outcome([]), do: :ok

  defp evaluate_outcome(results) do
    if Enum.all?(results, &match?({:error, _}, &1)) do
      {:error, "all scrape requests failed"}
    else
      :ok
    end
  end

  defp do_scrape_all(isbn_entries, stores) do
    client = Application.get_env(:core, :scraper_client, Stacks.Enrichment.ScraperClient)

    for %{isbn: isbn, book_id: book_id} <- isbn_entries,
        store <- stores do
      store_name = store.scraper_module || store.name

      case client.scrape(isbn, store_name) do
        {:ok, response} ->
          Monitoring.record_success(store_name, "scraper_config")

          {:ok,
           %{
             "book_id" => book_id,
             "store_id" => store.id,
             "price_cents" => response["price_cents"],
             "currency" => response["currency"] || "ZAR",
             "in_stock" => response["in_stock"],
             "url" => response["url"]
           }}

        {:error, reason} ->
          :fuse.melt(@fuse_name)
          Monitoring.record_failure(store_name, "scraper_config", inspect(reason))

          Logger.warning(
            "TriggerPriceScrapeJob: scrape failed isbn=#{isbn} store=#{store_name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end
end
