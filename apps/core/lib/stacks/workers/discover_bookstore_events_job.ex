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
        # Returns a *classified* success — `{:ok, :no_events_page}`, `{:ok, :blocked}`,
        # `{:ok, :paced}`, `{:ok, {:events, n}}` — which is already this worker's contract and is
        # what lets the batch summary tally the reasons apart. A robots block used to return a bare
        # `:ok` here, which is why it was invisible in that summary.
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

    # Collect outcomes rather than discarding them: a batch that writes zero events is the normal
    # case right now (no store has an events page), and the run has to make that legible. Without
    # the summary the only signal was an unchanged row count, which reads as breakage.
    stores
    |> Enum.map(&discover_for_store/1)
    |> summarise_batch(length(stores))

    :ok
  end

  # ⚠️ There is deliberately **no default events path any more.** This job used to fetch a hardcoded
  # `/events` on every store, and it 404s on every scrapeable one — which is why this pipeline had
  # never written a single row while every one of its tests passed on fixture bodies.
  #
  # `EventsPath.resolve/1` asks the shop's own sitemap instead, so a store with no known path gets
  # resolved rather than guessed at. Reintroducing a fallback constant would restore the quiet failure:
  # a guess that 404s looks exactly like a shop with no events.

  # The single-store entry point reaches here via `all_stores/0`, so unlike the batch
  # path it can still be handed a store with no registry key. Refuse explicitly rather
  # than asking the service about `null` — that produces a 404 whose message blames the
  # store rather than the missing config.
  # One line per run saying what actually happened, because "0 events" on its own is indistinguishable
  # from a broken pipeline — and was mistaken for one.
  defp summarise_batch(results, total) do
    # ⚠️ `blocked` was carried in this accumulator, never incremented and never printed: a
    # robots-blocked store returned a bare `:ok` and vanished into the no-op clause. So a batch in
    # which every store was blocked logged "0 event(s) written" with nothing accounting for it —
    # exactly the indistinguishable-from-broken reading this summary exists to prevent.
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

      # We could not find out where this shop's events live. `EventsPath` has already recorded WHY on
      # the store, with a timestamp, so this is re-checkable rather than a permanent write-off — and
      # it is deliberately not a failure: nothing is wrong with the job, and for `:no_candidate` the
      # shop genuinely has no events page, which is a normal fact about a bookshop.
      {:error, {:rate_limited, retry_after}} ->
        Logger.info(
          "DiscoverBookstoreEventsJob: #{store_name} asked us to back off for #{retry_after}s; " <>
            "skipping this run rather than retrying"
        )

        {:ok, :paced}

      # `EventsPath` has already recorded this — it is the only layer that knows *which* path was
      # refused, and recording it here as well would either duplicate the write or invent a path.
      {:error, {:robots_blocked, _rule}} ->
        {:ok, :blocked}

      # No listing page — which, for the shops we actually scrape, is the NORMAL answer (#382): they
      # publish events as individual pages. The walk's harvest rides along with the negative, so
      # classifying it costs the shop nothing beyond the fetches a real candidate earns.
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
      # Nothing changed since last time. The shop sent no body at all, which is the entire saving —
      # an events page is re-read on a schedule and changes rarely.
      #
      # ⚠️ Emphatically not "no events": the rows we already hold stay exactly as they are. Treating a
      # 304 as an empty page would delete every event this store has on the first unchanged run.
      {:ok, %{not_modified: true} = response} ->
        EventsPath.remember_validators(store, response)
        Monitoring.record_success(store_name, "event_source")
        Logger.info("DiscoverBookstoreEventsJob: #{store_name} unchanged since last fetch (304)")
        {:ok, :unchanged}

      {:ok, %{status: 200, body: body} = response} ->
        EventsPath.remember_validators(store, response)
        # A successful fetch is also the evidence that any recorded block has lifted.
        # Clearing here rather than on a separate schedule is what makes the block
        # self-healing without a second moving part.
        Prices.clear_robots_block(store)
        Monitoring.record_success(store_name, "event_source")
        persist_events(parse_events(body, store), store)

      # 404 is data: plenty of shops have no /events page. Recording it as a failure
      # would melt the store's fuse for a condition that is simply true of that shop.
      {:ok, %{status: 404}} ->
        # ⚠️ Was `Logger.debug`, i.e. invisible at the default level — so a batch run that wrote
        # nothing gave no reason at all, and read as a silent failure. It took a direct fetch to
        # establish that `/events` simply 404s on both scrapeable stores; that should have been in
        # the log. A zero-row outcome must explain itself or it will be mistaken for a defect.
        # The resolved path stopped serving. Clear it so the next run re-resolves rather than
        # re-fetching a path we now know is gone — the check belongs here, where the failure shows
        # up, which is why `EventsPath.resolve/1` does not re-verify a known path on every run.
        EventsPath.forget(store)

        Logger.info(
          "DiscoverBookstoreEventsJob: #{store_name} answered 404 at #{path}; " <>
            "cleared it so the next run re-resolves"
        )

        {:ok, :no_events_page}

      {:ok, %{status: status}} ->
        Monitoring.record_failure(store_name, "event_source", "HTTP #{status}")
        {:error, {:unexpected_status, status}}

      # The shop is pacing us. Like a robots.txt block this is a determination and not a failure,
      # but unlike one it resolves by itself — so it is neither recorded against the store's health
      # nor retried now. `{:ok, :paced}` rather than `{:error, …}` because the *job* did the right
      # thing; a shop asking us to wait is a normal outcome of a polite crawler, not an incident.
      #
      # Deliberately no snooze/retry here: `retry_after` is logged for an operator, and the next
      # scheduled run is well beyond any plausible cooldown. Holding a job open to sleep would tie
      # up a worker to accomplish waiting, which the schedule already does for free.
      {:error, {:rate_limited, retry_after}} ->
        Logger.info(
          "DiscoverBookstoreEventsJob: #{store_name} asked us to back off for #{retry_after}s; " <>
            "skipping this run rather than retrying"
        )

        {:ok, :paced}

      # A determination, not a failure. Record it and stop for this store: retrying
      # cannot succeed, and reporting it as an error would melt a fuse on every run.
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
        # The date from THIS heading's own block, or nil. Never from anywhere else — see
        # `heading_blocks/1`.
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
  Split a page into `{heading_text, block_html}` pairs, where a block runs from one heading to the
  next.

  ⚠️ **This replaces two independent scans whose results were paired by index**, which is the bug
  worth understanding before touching this. The old code took the nth `<h2>` and the nth ISO date
  found *anywhere in the document*. Those lists have no relationship: headings include site chrome
  ("Subscribe", "Follow us", "Disclaimer" — measured on a real Shopify page) and dates appear in
  footers, scripts and JSON-LD. So it manufactured confident, wrong records — an event titled
  "Follow us" carrying a date from an unrelated part of the page.

  That was then replaced by the opposite extreme: a date was used only if the *whole document*
  contained exactly one distinct date, and nil otherwise. Honest, but it means **a normal listing
  page — several events, several different dates — yields nothing at all**, which is how this
  pipeline stayed at zero rows even once it was fetching a real page.

  Block scoping is what makes pairing sound without a DOM parser: a date is used only if it appears
  after its own heading and before the next one, so a date can never be borrowed from another event
  or from page chrome. A heading whose block holds no date still gets `nil` — the strictness is kept
  exactly where it was earned.

  The final block stops at `<footer` when present, so a footer date cannot attach itself to the last
  event on the page.
  """
  @spec heading_blocks(String.t()) :: [{String.t(), String.t()}]
  def heading_blocks(body) do
    body = String.split(body, ~r/<footer[^>]*>/i, parts: 2) |> hd()

    # ONE scan. `return: :index` gives the full match *and* the capture group as `{offset, length}`
    # pairs, so the title comes out of the same pass — a second `Regex.scan` for the captures was
    # scanning the document twice and relying on both passes agreeing.
    #
    # Byte offsets, and `binary_part/3` is byte-based, so they match. Every boundary lands on ASCII
    # (`<h2…>` / `</h2>`), which is why a heading containing é or ë is never sliced mid-codepoint —
    # demonstrated by the "multi-byte headings are sliced correctly" test rather than merely reasoned
    # about.
    matches = Regex.scan(@heading_pattern, body, return: :index)

    # Each block ends where the next heading begins; the last runs to the end of the (footer-trimmed)
    # document. `Enum.drop(_, 1)` and not `tl/1`: a page with no headings gives an empty list, and
    # `tl([])` raises. Caught by the "handles HTML with no matching patterns" test — a good argument
    # for keeping unglamorous empty-input tests around.
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

  # Headings that are page furniture rather than events. Measured on a real Shopify storefront, where
  # every one of these renders as an `<h2>` — so without this filter a page reliably produces several
  # "events" named after its own navigation.
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

    # ⚠️ Returns the COUNT, and that is not cosmetic. This returned a bare `:ok`, which meant
    # `summarise_batch/2`'s `{:ok, {:events, n}}` clause never matched — so the batch summary reported
    # "0 event(s) written" on every run, including runs that wrote events. A dead clause in a summary
    # is worse than no summary: it reads as a measurement.
    #
    # Found by asserting on the return value of a full `perform/1`, which nothing did before.
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
