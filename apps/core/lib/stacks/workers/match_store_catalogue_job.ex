defmodule Stacks.Workers.MatchStoreCatalogueJob do
  @moduledoc """
  Prices books at the shops that carry no ISBN on any product, by matching titles.

  Ike's Books had no ISBN on any of 50 sampled products and Love Books none on 30, so
  no enumeration can map an ISBN to a product there. `StoreMatcher` matches the shop's
  titles against editions we hold, and each match is used immediately to fetch that
  product's price.

  ## Why no pointer table

  A match could be persisted and reused, but it would be a third thing to keep fresh —
  invalidated by the shop re-slugging, by our catalogue changing, and by the match
  thresholds being retuned. Since matching only applies to two shops and prices carry a
  staleness TTL anyway, the match is made and spent in one pass. If a third shop of
  this kind appears, or the sweep gets expensive, that is the moment to persist it.

  ## Why it is a separate job

  Fetching a shop's titles is a bulk sweep that waits on its rate limit and takes
  minutes, exactly like the index build, so it must never sit inside a request.
  """

  use Oban.Worker, queue: :scraper, max_attempts: 2

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment.{PricePipeline, Prices, StoreMatcher}

  # Editions attempted per store per run.
  #
  # Each match that succeeds costs one product fetch, against a shop limited to a few
  # requests a minute. Sweeping the whole catalogue in one run would take hours and
  # monopolise that budget; the TTL brings the rest around on later runs.
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
    # One job per store, so a failure at one shop does not lose the other's work.
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

  # Editions worth trying, newest first. Deliberately does not filter to unpriced
  # editions: a price at this store may be stale rather than absent, and the TTL is the
  # right arbiter of that, not this job.
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

  # This job's whole output for a non-priced outcome is a log line, so the log line
  # has to be true. It used to be a single catch-all reading "the match was plausible
  # but the product did not price… the likely cause is a wrong match" — a diagnosis
  # that is correct only for NOT_STOCKED. It quietly mislabelled our own broken
  # extractor, a shop's robots rule, and a shop pacing us as bad title matches, at
  # `info`, which is precisely how the RATE_LIMITED miss stayed invisible for three
  # campaigns. One clause per outcome, and `scripts/check-enum-coverage.py` keeps it
  # that way.
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

  # The one outcome that really does indict the match: we matched a title to a
  # product the shop says it does not carry at this ISBN.
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

  # The shop is pacing us. Not a bad match and not our defect — the shop exercising a
  # right we should be honouring. Enforcing the cooldown belongs in `RateLimiter`, so
  # it holds for every caller rather than the ones that remember (Issue #308); here it
  # must at least stop being logged as a match failure.
  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_RATE_LIMITED"} = response, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: #{ctx.store_name} rate-limited us for #{ctx.path}: " <>
        "#{response["detail"]}"
    )
  end

  # Our extractor is broken for this store. The match may well have been perfect.
  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_EXTRACTOR_FAILED"} = response, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: extractor failed for #{ctx.store_name} at #{ctx.path}: " <>
        "#{response["detail"] || "no detail"}"
    )
  end

  # Cannot arise on this path: we scrape an explicit product path found by title
  # matching, so no ISBN index is consulted. Named rather than lumped in with the
  # unknown case, because if it ever does appear the scraper's contract has changed
  # under us and that is worth saying plainly.
  defp interpret(%{"outcome" => "SCRAPE_OUTCOME_INDEX_REQUIRED"}, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: #{ctx.store_name} asked for an ISBN index while scraping " <>
        "the explicit path #{ctx.path} — the scraper contract has changed"
    )
  end

  # Absent or unrecognised: a response that cannot say what it concluded is not
  # evidence that nothing went wrong. Also catches a scraper older than this contract.
  defp interpret(response, ctx) do
    Logger.warning(
      "MatchStoreCatalogueJob: unrecognised outcome #{inspect(response["outcome"])} from " <>
        "#{ctx.store_name} for #{ctx.path}"
    )
  end
end
