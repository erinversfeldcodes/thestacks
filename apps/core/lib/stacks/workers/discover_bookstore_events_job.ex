defmodule Stacks.Workers.DiscoverBookstoreEventsJob do
  @moduledoc """
  Oban worker that discovers events at bookstores by scraping their websites.

  Accepts `%{"store_id" => id}` for a single bookstore, or `%{"batch" => true}`
  to process all bookstores with a `website_url` set.

  For each store, fetches the events page, parses event data, and links to
  known authors when an author name matches the event title or description.

  ## Compliance

  The page is fetched through `ScraperClient.fetch_page/2`, which is the scraper
  service's single compliant egress: robots.txt is consulted first, then the rate
  limiter, and both circuit breakers gate the call.

  ⚠️ This job previously issued a **bare `Finch.build(:get, "\#{website_url}/events")`**
  with no robots check, no rate limit and no fuse — a direct violation of the project's
  hard rule that robots.txt stops a scrape. It was never scheduled, so nothing was
  actually fetched non-compliantly, but the violation sat in the code waiting for
  whoever wired the job up. Fixing the egress before that happened is the whole point:
  the next person to schedule this will not think to check.

  A robots disallow is recorded on the store (`Prices.record_robots_block/3`) and the
  job **stops for that store** — it does not retry, and it does not try another path.
  A later successful fetch clears the block, so a lifted disallow resumes by itself.

  Only stores with a scraper config can be fetched at all, because the config supplies
  the base URL and the rate limit. A store without one is skipped and says so.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Books.Author
  alias Stacks.Enrichment.{Events, Prices, ScraperClient}
  alias Stacks.Monitoring

  @impl true
  def perform(%Oban.Job{args: %{"store_id" => store_id}}) do
    store = Prices.all_stores() |> Enum.find(&(&1.id == store_id))

    case store do
      nil ->
        Logger.warning("DiscoverBookstoreEventsJob: store #{store_id} not found")
        {:cancel, "store not found"}

      store ->
        discover_for_store(store)
    end
  end

  def perform(%Oban.Job{args: %{"batch" => true}}) do
    # `scrapeable_stores/0`, not `all_stores/0`: the compliant egress is keyed by scraper
    # config, which supplies the base URL *and* the rate limit. A store with a website
    # but no config cannot be fetched at all — deliberately, since no config means no
    # declared crawl policy and guessing one is how the hard rule becomes advisory.
    stores = Prices.scrapeable_stores()
    skipped = length(Prices.all_stores()) - length(stores)

    if skipped > 0 do
      Logger.info(
        "DiscoverBookstoreEventsJob: skipping #{skipped} store(s) with no scraper config"
      )
    end

    Logger.info("DiscoverBookstoreEventsJob: processing #{length(stores)} stores in batch")

    Enum.each(stores, &discover_for_store/1)

    :ok
  end

  # The path fetched on every store. Relative, because the compliant egress resolves
  # it against the store's *configured* base URL rather than trusting a caller-supplied
  # host — see `ScraperClient.fetch_page/2`.
  @events_path "/events"

  # The single-store entry point reaches here via `all_stores/0`, so unlike the batch
  # path it can still be handed a store with no registry key. Refuse explicitly rather
  # than asking the service about `null` — that produces a 404 whose message blames the
  # store rather than the missing config.
  defp discover_for_store(%{scraper_module: nil} = store) do
    Logger.info(
      "DiscoverBookstoreEventsJob: #{store.name || store.id} has no scraper config; " <>
        "not fetching (no config means no declared crawl policy)"
    )

    :ok
  end

  defp discover_for_store(store) do
    store_name = store.name || store.id

    case ScraperClient.fetch_page(store.scraper_module, @events_path) do
      {:ok, %{status: 200, body: body}} ->
        # A successful fetch is also the evidence that any recorded block has lifted.
        # Clearing here rather than on a separate schedule is what makes the block
        # self-healing without a second moving part.
        Prices.clear_robots_block(store)
        Monitoring.record_success(store_name, "event_source")
        persist_events(parse_events(body, store), store)

      # 404 is data: plenty of shops have no /events page. Recording it as a failure
      # would melt the store's fuse for a condition that is simply true of that shop.
      {:ok, %{status: 404}} ->
        Logger.debug("DiscoverBookstoreEventsJob: no events page at #{store_name}")
        :ok

      {:ok, %{status: status}} ->
        Monitoring.record_failure(store_name, "event_source", "HTTP #{status}")
        {:error, {:unexpected_status, status}}

      # A determination, not a failure. Record it and stop for this store: retrying
      # cannot succeed, and reporting it as an error would melt a fuse on every run.
      {:error, {:robots_blocked, rule}} ->
        Prices.record_robots_block(store, @events_path, rule)
        :ok

      {:error, reason} ->
        Monitoring.record_failure(store_name, "event_source", inspect(reason))

        Logger.warning(
          "DiscoverBookstoreEventsJob: fetch failed for store #{store.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Parses event data from an HTML body. Uses simple regex-based extraction
  to find event titles, dates, and descriptions.

  Returns a list of maps with `:title`, `:event_date`, `:description`,
  `:location`, and `:url` keys.
  """
  @spec parse_events(String.t(), map()) :: [map()]
  def parse_events(body, store) do
    # Simple regex-based extraction for common event listing patterns.
    # Matches patterns like:
    #   <h2>Event Title</h2> or <h3 class="...">Event Title</h3>
    #   with date patterns like "2026-03-20" or "March 20, 2026"
    title_pattern = ~r/<h[23][^>]*>([^<]+)<\/h[23]>/i
    date_pattern = ~r/(\d{4}-\d{2}-\d{2})/

    titles = Regex.scan(title_pattern, body) |> Enum.map(fn [_, title] -> String.trim(title) end)
    dates = Regex.scan(date_pattern, body) |> Enum.map(fn [_, date] -> date end)

    authors = load_known_authors()

    titles
    |> Enum.with_index()
    |> Enum.map(fn {title, idx} ->
      raw_date = Enum.at(dates, idx)
      author_id = match_author(title, authors)

      %{
        store_id: store.id,
        title: title,
        event_date: parse_date(raw_date),
        description: nil,
        location: nil,
        url: store.website_url,
        author_id: author_id,
        scraped_at: DateTime.utc_now()
      }
    end)
  end

  defp persist_events(events, store) do
    results =
      Enum.map(events, fn event_attrs ->
        case Events.upsert_event(event_attrs) do
          {:ok, event} ->
            {:ok, event}

          {:error, changeset} ->
            Logger.warning(
              "DiscoverBookstoreEventsJob: failed to upsert event: #{inspect(changeset.errors)}"
            )

            {:error, changeset}
        end
      end)

    successes = Enum.count(results, &match?({:ok, _}, &1))

    if successes > 0 do
      Stacks.Events.emit_safe(%{
        event_type: "enrichment.events_discovered",
        aggregate_type: "bookstore",
        aggregate_id: store.id,
        payload: %{events_count: successes, store_name: store.name},
        metadata: %{actor: "system:discover_bookstore_events_job"}
      })
    end

    :ok
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_string) do
    case DateTime.from_iso8601("#{date_string}T00:00:00Z") do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp load_known_authors do
    import Ecto.Query
    Core.Repo.all(from(a in Author, select: {a.id, a.name}))
  rescue
    e ->
      Logger.warning(
        "DiscoverBookstoreEventsJob: failed to load authors: #{Exception.message(e)}"
      )

      []
  end

  defp match_author(title, authors) do
    downcased = String.downcase(title)

    Enum.find_value(authors, fn {id, name} ->
      if String.contains?(downcased, String.downcase(name)), do: id
    end)
  end
end
