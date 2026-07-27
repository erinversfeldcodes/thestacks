defmodule Stacks.Workers.TriggerPriceScrapeJob do
  @moduledoc """
  Oban worker that triggers price scraping for a book's ISBN across bookstores.

  ## Modes

  - **Single ISBN:** `%{isbn: "978...")` — scrapes this ISBN at all stores.
    `book_edition_id` may be supplied when the caller already knows it.
  - **Batch:** `%{batch: true}` — finds all stale editions and scrapes them.

  Prices are recorded against the **edition**, since an ISBN names an edition and
  shops stock whichever editions they stock, at different prices.

  Results are pushed to `PricePipeline` (Broadway) for batched persistence.

  Circuit breaker protection is handled at the `ScraperClient` level (`:scraper_fuse`).
  When the circuit is open, `ScraperClient.scrape/2` returns `{:error, :circuit_open}`,
  which is treated the same as any other scrape failure by this worker.
  """

  use Oban.Worker, queue: :scraper, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Stacks.Enrichment.PricePipeline
  alias Stacks.Enrichment.Prices
  alias Stacks.Monitoring

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

  # An ISBN identifies an *edition*, not a work — a work has many ISBNs (Exclusive
  # Books stocks six for The Name of the Rose). So the edition is what gets priced.
  # Callers may pass `book_edition_id` when they already know it (the batch path
  # does); otherwise it is resolved from the ISBN, which is the edition's natural
  # key. A `book_id` in the args is ignored: it cannot say which edition was meant.
  def perform(%Oban.Job{args: %{"isbn" => isbn} = args}) do
    Logger.info("TriggerPriceScrapeJob: scraping isbn=#{isbn}")

    case args["book_edition_id"] || edition_id_for_isbn(isbn) do
      nil ->
        # Not an error: the edition row may not exist yet, or the ISBN may have
        # been removed. The nightly batch walks editions directly and will pick
        # it up once it exists, so discarding beats retrying five times.
        Logger.info("TriggerPriceScrapeJob: no edition for isbn=#{isbn}, skipping")
        :ok

      book_edition_id ->
        stores = Prices.all_stores()

        if Enum.empty?(stores) do
          Logger.info("TriggerPriceScrapeJob: no stores configured, skipping")
          :ok
        else
          scrape_all([%{isbn: isbn, book_edition_id: book_edition_id}], stores)
        end
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("TriggerPriceScrapeJob: unrecognized args: #{inspect(args)}")
    :ok
  end

  defp edition_id_for_isbn(isbn) do
    Core.Repo.one(
      from(be in Stacks.Books.BookEdition, where: be.isbn == ^isbn, select: be.id, limit: 1)
    )
  end

  defp scrape_all(isbn_entries, stores) do
    results = do_scrape_all(isbn_entries, stores)
    push_successful_results(results)
    evaluate_outcome(results)
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

    for %{isbn: isbn, book_edition_id: book_edition_id} <- isbn_entries,
        store <- stores do
      store_name = store.scraper_module || store.name

      case client.scrape(isbn, store_name) do
        {:ok, response} ->
          Monitoring.record_success(store_name, "scraper_config")

          {:ok,
           %{
             "book_edition_id" => book_edition_id,
             "store_id" => store.id,
             "price_cents" => response["price_cents"],
             "currency" => response["currency"] || "ZAR",
             "in_stock" => response["in_stock"],
             "url" => response["url"]
           }}

        {:error, reason} ->
          Monitoring.record_failure(store_name, "scraper_config", inspect(reason))

          Logger.warning(
            "TriggerPriceScrapeJob: scrape failed isbn=#{isbn} store=#{store_name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end
end
