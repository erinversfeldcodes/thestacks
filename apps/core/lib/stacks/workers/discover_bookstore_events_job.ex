defmodule Stacks.Workers.DiscoverBookstoreEventsJob do
  @moduledoc """
  Oban worker discovering bookstore events from their websites. Args:
  `%{"store_id" => id}` or `%{"batch" => true}` (all stores with a
  `website_url`). Parses the events page and links known authors by name.

  Compliance: fetches ONLY through `ScraperClient.fetch_page/2` (robots.txt,
  rate limiter, both fuses). This job once built a bare Finch GET with none
  of those — never scheduled, but waiting for whoever wired it up. A robots
  disallow is recorded as a determination and the store is skipped, not
  retried.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Books.Author
  alias Stacks.Enrichment.{EventExtractor, EventPages, Events, EventsPath, Prices, ScraperClient}
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
    stores = Prices.scrapeable_stores()
    skipped = length(Prices.all_stores()) - length(stores)

    if skipped > 0 do
      Logger.info(
        "DiscoverBookstoreEventsJob: skipping #{skipped} store(s) with no scraper config"
      )
    end

    Logger.info("DiscoverBookstoreEventsJob: processing #{length(stores)} stores in batch")

    stores
    |> Enum.map(&discover_for_store/1)
    |> summarise_batch(length(stores))

    :ok
  end

  defp summarise_batch(results, total) do
    tally =
      Enum.reduce(
        results,
        %{events: 0, no_page: 0, blocked: 0, paced: 0, unchanged: 0, failed: 0},
        fn
          {:ok, :no_events_page}, acc -> %{acc | no_page: acc.no_page + 1}
          {:ok, {:events, n}}, acc -> %{acc | events: acc.events + n}
          {:ok, :blocked}, acc -> %{acc | blocked: acc.blocked + 1}
          {:ok, :paced}, acc -> %{acc | paced: acc.paced + 1}
          {:ok, :unchanged}, acc -> %{acc | unchanged: acc.unchanged + 1}
          :ok, acc -> acc
          {:error, _}, acc -> %{acc | failed: acc.failed + 1}
          _, acc -> acc
        end
      )

    Logger.info(
      "DiscoverBookstoreEventsJob: batch done — #{total} store(s): " <>
        "#{tally.events} event(s) written, #{tally.no_page} with no events page, " <>
        "#{tally.blocked} blocked by robots.txt, #{tally.paced} asked us to back off, " <>
        "#{tally.failed} failed"
    )

    :ok
  end

  defp discover_for_store(%{scraper_module: nil} = store) do
    Logger.info(
      "DiscoverBookstoreEventsJob: #{store.name || store.id} has no scraper config; " <>
        "not fetching (no config means no declared crawl policy)"
    )

    :ok
  end

  defp discover_for_store(store) do
    store_name = store.name || store.id

    case EventsPath.resolve(store) do
      {:ok, path} ->
        fetch_events(store, store_name, path)

      {:error, {:rate_limited, retry_after}} ->
        Logger.info(
          "DiscoverBookstoreEventsJob: #{store_name} asked us to back off for #{retry_after}s; " <>
            "skipping this run rather than retrying"
        )

        {:ok, :paced}

      {:error, {:robots_blocked, _rule}} ->
        {:ok, :blocked}

      {:error, {:no_candidate, urls}} ->
        EventPages.discover_and_store(urls, store)

      {:error, reason} ->
        Logger.info(
          "DiscoverBookstoreEventsJob: #{store_name} has no resolvable events page (#{inspect(reason)})"
        )

        {:ok, :no_events_page}
    end
  end

  defp fetch_events(store, store_name, path) do
    validators = [etag: store.events_page_etag, last_modified: store.events_page_last_modified]

    case ScraperClient.fetch_page(store.scraper_module, path, validators) do
      {:ok, %{not_modified: true} = response} ->
        EventsPath.remember_validators(store, response)
        Monitoring.record_success(store_name, "event_source")
        Logger.info("DiscoverBookstoreEventsJob: #{store_name} unchanged since last fetch (304)")
        {:ok, :unchanged}

      {:ok, %{status: 200, body: body} = response} ->
        EventsPath.remember_validators(store, response)
        Prices.clear_robots_block(store)
        Monitoring.record_success(store_name, "event_source")
        persist_events(parse_events(body, store), store)

      {:ok, %{status: 404}} ->
        EventsPath.forget(store)

        Logger.info(
          "DiscoverBookstoreEventsJob: #{store_name} answered 404 at #{path}; " <>
            "cleared it so the next run re-resolves"
        )

        {:ok, :no_events_page}

      {:ok, %{status: status}} ->
        Monitoring.record_failure(store_name, "event_source", "HTTP #{status}")
        {:error, {:unexpected_status, status}}

      {:error, {:rate_limited, retry_after}} ->
        Logger.info(
          "DiscoverBookstoreEventsJob: #{store_name} asked us to back off for #{retry_after}s; " <>
            "skipping this run rather than retrying"
        )

        {:ok, :paced}

      {:error, {:robots_blocked, rule}} ->
        Prices.record_robots_block(store, path, rule)
        {:ok, :blocked}

      {:error, reason} ->
        Monitoring.record_failure(store_name, "event_source", inspect(reason))

        Logger.warning(
          "DiscoverBookstoreEventsJob: fetch failed for store #{store.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Parses event data from an HTML body.

  Structured tier first (US-2.4.1 / #321 item 4): schema.org `Event` objects
  from the page's JSON-LD, which carry their own title↔date pairing and are
  believed over any text heuristic. Only a page declaring NO structured events
  falls through to the heading-block extraction below.

  Returns a list of maps with `:title`, `:event_date`, `:description`,
  `:location`, and `:url` keys.
  """
  @spec parse_events(String.t(), map()) :: [map()]
  def parse_events(body, store) do
    authors = load_known_authors()

    case EventExtractor.events(body) do
      [] ->
        heading_block_events(body, store, authors)

      structured ->
        Enum.map(structured, fn event ->
          event
          |> Map.merge(%{
            store_id: store.id,
            url: event.url || store.website_url,
            author_id: match_author(event.title, authors),
            scraped_at: DateTime.utc_now()
          })
        end)
    end
  end

  defp heading_block_events(body, store, authors) do
    body
    |> heading_blocks()
    |> Enum.reject(fn {title, _block} -> chrome_heading?(title) end)
    |> Enum.map(fn {title, block} ->
      %{
        store_id: store.id,
        title: title,
        event_date: block |> first_date() |> parse_date(),
        description: nil,
        location: nil,
        url: store.website_url,
        author_id: match_author(title, authors),
        scraped_at: DateTime.utc_now()
      }
    end)
  end

  @heading_pattern ~r/<h[23][^>]*>([^<]+)<\/h[23]>/i
  @date_pattern ~r/(\d{4}-\d{2}-\d{2})/

  @doc """
  Split a page into `{heading_text, block_html}` pairs (a block runs
  heading→next heading). Block scoping is what makes heading/date pairing
  sound without a DOM parser: a date only counts when it appears in the SAME
  block as its heading. The two prior designs both failed — pairing nth
  heading with nth date anywhere in the document manufactured confident
  wrong records ("Follow us" + a footer date); requiring one distinct date
  per whole document yielded zero rows on any normal multi-event listing.
  """
  @spec heading_blocks(String.t()) :: [{String.t(), String.t()}]
  def heading_blocks(body) do
    body = String.split(body, ~r/<footer[^>]*>/i, parts: 2) |> hd()

    matches = Regex.scan(@heading_pattern, body, return: :index)

    block_ends =
      matches
      |> Enum.map(fn [{offset, _} | _] -> offset end)
      |> Enum.drop(1)
      |> Kernel.++([byte_size(body)])

    matches
    |> Enum.zip(block_ends)
    |> Enum.map(fn {[{m_start, m_len}, {t_start, t_len}], block_end} ->
      block_start = m_start + m_len

      {String.trim(binary_part(body, t_start, t_len)),
       binary_part(body, block_start, max(block_end - block_start, 0))}
    end)
  end

  @chrome_headings ~w(subscribe newsletter follow disclaimer privacy terms cart menu search
                      shipping returns contact about login account checkout)

  defp chrome_heading?(title) do
    lower = String.downcase(title)
    Enum.any?(@chrome_headings, &String.contains?(lower, &1))
  end

  defp first_date(block) do
    case Regex.run(@date_pattern, block) do
      [_, date] -> date
      _ -> nil
    end
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

    {:ok, {:events, successes}}
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
