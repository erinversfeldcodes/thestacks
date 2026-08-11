defmodule Stacks.Workers.MatchStoreCatalogueJob do
  @moduledoc """
    Prices books at the no-ISBN shops (Ike's Books, Love Books) by title
    matching: `StoreMatcher` matches the shop's titles against our editions
    and each match is spent immediately on a price fetch. No pointer table —
    a persisted match would be a third thing to keep fresh (re-slugging,
    catalogue changes, threshold retuning) for only two shops whose prices
    carry a TTL anyway; persist when a third shop appears. A separate job
    because the title sweep waits minutes on the shop's rate limit and must
    not sit inside the ordinary scrape path.
  """

  use Oban.Worker, queue: :scraper, max_attempts: 2

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment.{PricePipeline, Prices, StoreMatcher}

  @editions_per_run 25

  @impl true
  def perform(%Oban.Job{args: %{"store" => store_name}}) do
    client = Application.get_env(:core, :scraper_client, Stacks.Enrichment.ScraperClient)

    with {:ok, store} <- fetch_store(store_name),
         {:ok, titles} <- client.catalogue_titles(store_name) do
      listings = Enum.map(titles, &{&1["product_path"], &1["title"]})
      match_and_price(client, store, store_name, listings)
    else
      {:error, reason} ->
        Logger.warning("MatchStoreCatalogueJob: #{store_name} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{}}) do
    stores = Prices.stores_needing_title_match()

    Enum.each(stores, fn store ->
      %{store: store.scraper_module}
      |> __MODULE__.new(unique: [period: 3600, fields: [:worker, :args]])
      |> Oban.insert()
    end)

    Logger.info("MatchStoreCatalogueJob: enqueued #{length(stores)} title-match sweep(s)")
    :ok
  end

  defp fetch_store(store_name) do
    case Enum.find(Prices.all_stores(), &(&1.scraper_module == store_name)) do
      nil -> {:error, :unknown_store}
      store -> {:ok, store}
    end
  end

  defp match_and_price(_client, _store, store_name, []) do
    Logger.info("MatchStoreCatalogueJob: #{store_name} listed no unmatched titles")
    :ok
  end

  defp match_and_price(client, store, store_name, listings) do
    matched =
      candidate_editions()
      |> Enum.reduce(0, fn edition, count ->
        case StoreMatcher.match_edition(listings, %{title: edition.title, author: edition.author}) do
          {:ok, path, score} ->
            price_matched(client, store, store_name, edition, path, score)
            count + 1

          :no_match ->
            count
        end
      end)

    Logger.info(
      "MatchStoreCatalogueJob: #{store_name} matched #{matched} of " <>
        "#{@editions_per_run} attempted editions"
    )

    :ok
  end

  defp candidate_editions do
    Core.Repo.all(
      from e in BookEdition,
        join: b in assoc(e, :book),
        left_join: a in assoc(b, :author),
        order_by: [desc: e.created_at],
        limit: @editions_per_run,
        select: %{id: e.id, isbn: e.isbn, title: b.title, author: a.name}
    )
  end

  defp price_matched(client, store, store_name, edition, path, score) do
    Logger.info(
      "MatchStoreCatalogueJob: #{store_name} matched #{inspect(edition.title)} " <>
        "to #{path} (score #{Float.round(score * 1.0, 2)})"
    )

    case client.scrape(edition.isbn, store_name, path) do
      {:ok, response} ->
        interpret(response, %{store: store, store_name: store_name, edition: edition, path: path})

      {:error, reason} ->
        Logger.warning("MatchStoreCatalogueJob: #{path} failed: #{inspect(reason)}")
    end
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_PRICED"} = response, ctx) do
    %{store: store, edition: edition} = ctx

    Broadway.push_messages(PricePipeline, [
      %Broadway.Message{
        data: %{
          "book_edition_id" => edition.id,
          "store_id" => store.id,
          "price_cents" => response["price_cents"],
          "currency" => response["currency"] || "ZAR",
          "in_stock" => response["in_stock"],
          "url" => response["url"]
        },
        acknowledger: Broadway.NoopAcknowledger.init()
      }
    ])
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_NOT_STOCKED"}, ctx) do
    Logger.info("MatchStoreCatalogueJob: #{ctx.path} does not stock this edition — match spent")
  end

  # Nothing to do with the match: robots.txt forbids this product path, so no amount
  # of better matching will price it until the rule is lifted.
  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_ROBOTS_BLOCKED"} = response, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: robots.txt blocks #{ctx.store_name} for #{ctx.path}: " <>
        "#{response["detail"]}"
    )
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_RATE_LIMITED"} = response, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: #{ctx.store_name} rate-limited us for #{ctx.path}: " <>
        "#{response["detail"]}"
    )
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_EXTRACTOR_FAILED"} = response, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: extractor failed for #{ctx.store_name} at #{ctx.path}: " <>
        "#{response["detail"] || "no detail"}"
    )
  end

  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_INDEX_REQUIRED"}, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: #{ctx.store_name} asked for an ISBN index while scraping " <>
        "the explicit path #{ctx.path} — the scraper contract has changed"
    )
  end

  defp interpret(response, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: unrecognised outcome #{inspect(response["outcome"])} from " <>
        "#{ctx.store_name} for #{ctx.path}"
    )
  end
end
