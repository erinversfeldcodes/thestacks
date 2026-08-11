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
  alias Stacks.Workers.BuildScraperIndexJob

  @impl true
  def perform(%Oban.Job{args: %{"batch" => true}}) do
    Logger.info("TriggerPriceScrapeJob: starting batch scrape")
    stale = Prices.stale_isbns(7)
    stores = Prices.scrapeable_stores()

    if Enum.empty?(stale) or Enum.empty?(stores) do
      Logger.info(
        "TriggerPriceScrapeJob: nothing to scrape (stale=#{length(stale)} stores=#{length(stores)})"
      )

      :ok
    else
      scrape_all(stale, stores)
    end
  end

  def perform(%Oban.Job{args: %{"isbn" => isbn} = args}) do
    Logger.info("TriggerPriceScrapeJob: scraping isbn=#{isbn}")

    case args["book_edition_id"] || edition_id_for_isbn(isbn) do
      nil ->
        Logger.info("TriggerPriceScrapeJob: no edition for isbn=#{isbn}, skipping")
        :ok

      book_edition_id ->
        stores = Prices.scrapeable_stores()

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
      store_name = store.scraper_module

      case client.scrape(isbn, store_name) do
        {:ok, response} ->
          Prices.record_capability(store, response["capability"])

          interpret(response, %{
            isbn: isbn,
            store: store,
            store_name: store_name,
            edition_id: book_edition_id
          })

        {:error, reason} ->
          Monitoring.record_failure(store_name, "scraper_config", inspect(reason))

          Logger.warning(
            "TriggerPriceScrapeJob: scrape failed isbn=#{isbn} store=#{store_name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_PRICED"} = response, ctx) do
    %{store: store, store_name: store_name, edition_id: edition_id} = ctx

    Monitoring.record_success(store_name, "scraper_config")

    Prices.note_canary(store, ctx.isbn)

    {:ok,
     %{
       "book_edition_id" => edition_id,
       "store_id" => store.id,
       "price_cents" => response["price_cents"],
       "currency" => response["currency"] || "ZAR",
       "in_stock" => response["in_stock"],
       "url" => response["url"]
     }}
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_NOT_STOCKED"}, ctx) do
    %{isbn: isbn, store: store, store_name: store_name} = ctx

    Monitoring.record_success(store_name, "scraper_config")

    case Prices.canary_failed(store, isbn) do
      :ok ->
        :ok

      :not_canary ->
        Logger.debug("TriggerPriceScrapeJob: #{store_name} does not stock isbn=#{isbn}")
    end

    {:determined, :not_stocked}
  end

  # robots.txt forbids the path. Also not a failure: the store's configuration
  # stays in place so this resolves itself if the rule is lifted. Logged at warning
  # because it means we will never get a price here until then.
  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_ROBOTS_BLOCKED"} = response, ctx) do
    %{isbn: isbn, store_name: store_name} = ctx

    Monitoring.record_success(store_name, "scraper_config")

    Logger.warning(
      "TriggerPriceScrapeJob: robots.txt blocks #{store_name} for isbn=#{isbn}: " <>
        "#{response["detail"]}"
    )

    {:determined, :robots_blocked}
  end

  # The shop is pacing us — 429, or a cooldown it asked for. A determination,
  # not a failure: it is neither our defect nor a service failure, and it
  # recurs on every attempt until the cooldown lapses, so counting it against
  # the shared fuse (or letting Oban retry it) is the identical trap
  # ROBOTS_BLOCKED was split out to avoid. The store stays configured; the
  # next scheduled pass simply asks again later.
  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_RATE_LIMITED"} = response, ctx) do
    %{isbn: isbn, store_name: store_name} = ctx

    Monitoring.record_success(store_name, "scraper_config")

    Logger.info(
      "TriggerPriceScrapeJob: #{store_name} rate-limited us for isbn=#{isbn}: " <>
        "#{response["detail"]}"
    )

    {:determined, :rate_limited}
  end

  # The store needs an ISBN index and none exists. Build one, then this ISBN resolves
  # on the next attempt.
  #
  # This is what keeps the four index-needing shops working without depending on a
  # schedule: the index lives in the scraper service's process and dies with it, so a
  # restart would otherwise leave them unpriceable until the nightly rebuild. Reacting
  # to the outcome makes the cron a belt-and-braces refresh rather than the only path.
  #
  # Not counted as a failure: nothing is broken, we simply cannot answer yet.
  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_INDEX_REQUIRED"}, ctx) do
    %{isbn: isbn, store_name: store_name} = ctx

    Monitoring.record_success(store_name, "scraper_config")

    %{store: store_name}
    |> BuildScraperIndexJob.new(unique: [period: 3600, fields: [:worker, :args]])
    |> Oban.insert()

    Logger.info(
      "TriggerPriceScrapeJob: #{store_name} needs an ISBN index for isbn=#{isbn}; " <>
        "build enqueued"
    )

    {:determined, :index_required}
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_EXTRACTOR_FAILED"} = response, ctx) do
    %{isbn: isbn, store_name: store_name} = ctx

    detail = response["detail"] || "no detail"
    Monitoring.record_failure(store_name, "scraper_config", detail)

    Logger.warning(
      "TriggerPriceScrapeJob: extractor failed for #{store_name} isbn=#{isbn}: #{detail}"
    )

    {:error, :extractor_failed}
  end

  defp interpret(response, ctx) do
    %{isbn: isbn, store_name: store_name} = ctx

    outcome = response["outcome"]

    Monitoring.record_failure(
      store_name,
      "scraper_config",
      "unrecognised outcome #{inspect(outcome)}"
    )

    Logger.warning(
      "TriggerPriceScrapeJob: unrecognised outcome #{inspect(outcome)} from #{store_name} " <>
        "for isbn=#{isbn} — treating as failure"
    )

    {:error, {:unrecognised_outcome, outcome}}
  end
end
