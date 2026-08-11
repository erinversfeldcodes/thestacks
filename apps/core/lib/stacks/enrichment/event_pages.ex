defmodule Stacks.Enrichment.EventPages do
  @moduledoc """
  Finds events that a shop publishes as **individual pages**, because that is how these shops
  actually publish them.

  ## Why this exists

  #307 built polite discovery on the premise of an events *listing* page — one URL, many events.
  Driven live (2026-08-04), the premise failed: neither scrapeable shop has one. What Wordsworth has
  is `/pages/treive-nicholas-book-signing-at-our-sea-point-store` — **one event, as its own page** —
  sitting in its sitemap between `/pages/careers-at-wordsworth-books` and `/pages/payment-logos`.
  `EventsPath` is correct when it answers "no listing page"; this module is what runs on that answer.

  ## The classifier, and why its negatives matter more than its positives

  A slug is classified as an event only if it contains one of a short list of **event-shaped
  phrases** (`book-signing`, `book-launch`, `author-evening`, …). The list is deliberately precise
  rather than broad, because the failure modes are asymmetric: a missed event costs us one listing,
  while a false positive *invents* an event — and a pipeline that invents records is harder to
  notice and harder to undo than one that produces none (`parse_events/2` learned this the hard
  way).

  The ground truth is the shop's real page list: 45 slugs, exactly one event, and 44 negatives that
  include every tempting near-miss — `halloween` (a themed shopping page), `mothers-day-promotion`,
  `celebrate-our-birthday-with-us-chapter30`, `book-of-the-month-subscription`. None of them match,
  and the test suite pins all 45.

  ## What is stored, and what is refused

  A candidate earns **one fetch** (through the compliant egress: robots, rate limit, the fuse). The
  title comes from the page's own `<title>`; the date is extracted **only** if the page states one
  unambiguously, and the real page states none — so most rows will be dateless, which is why
  `event_date` became optional (#382, owner ruling). The URL stored is the shop's own page: the
  reader follows it for the details we refuse to guess at.

  At most `@max_candidates_per_run` pages are fetched per store per run, so a hostile or weird
  sitemap cannot turn classification into a crawl.
  """

  alias Stacks.Enrichment.EventExtractor
  alias Stacks.Enrichment.Events
  alias Stacks.Enrichment.EventsPath

  require Logger

  @doc """
  Phrases that mark a page slug as an event, checked as substrings of the URL's last path segment.

  Multi-word and specific on purpose — `signing` alone would match a hypothetical
  `/pages/sign-up-for-signings-newsletter`, but the hyphenated forms a slug actually takes
  (`book-signing`, `author-signing`) do not. Public so the tests enumerate the real list.
  """
  @event_phrases ~w(
    book-signing author-signing book-launch author-evening author-event
    meet-the-author author-talk poetry-evening poetry-reading open-mic
    story-time storytime book-reading literary-festival author-visit
  )
  def event_phrases, do: @event_phrases

  @max_candidates_per_run 5

  @doc """
  Classify a page URL: does its slug name an event?

  Pure, so the 45-slug ground truth is testable without a network.
  """
  @spec event_page?(String.t()) :: boolean()
  def event_page?(url) do
    slug =
      url
      |> String.split("?", parts: 2)
      |> hd()
      |> String.trim_trailing("/")
      |> String.split("/")
      |> List.last()
      |> to_string()
      |> String.downcase()

    Enum.any?(@event_phrases, &String.contains?(slug, &1))
  end

  @doc """
  Classify `urls`, fetch the candidates, and store one event per page that yields one.

  Returns `{:ok, {:events, n}}` with the number stored, or `{:ok, :no_events_page}` when nothing
  classified as an event — the same vocabulary the job's batch summary already tallies.
  """
  @spec discover_and_store([String.t()], map()) ::
          {:ok, {:events, non_neg_integer()}} | {:ok, :no_events_page}
  def discover_and_store(urls, store) do
    candidates = Enum.filter(urls, &event_page?/1)

    over = length(candidates) - @max_candidates_per_run

    if over > 0 do
      Logger.warning(
        "EventPages: #{store.name || store.id} has #{length(candidates)} event-page candidates; " <>
          "fetching #{@max_candidates_per_run} and leaving #{over} for the next run"
      )
    end

    stored =
      candidates
      |> Enum.take(@max_candidates_per_run)
      |> Enum.map(&fetch_and_store(&1, store))
      |> Enum.count(&match?({:ok, _}, &1))

    if stored > 0 do
      {:ok, {:events, stored}}
    else
      {:ok, :no_events_page}
    end
  end

  defp fetch_and_store(url, store) do
    path = EventsPath.path_of(url)

    case client().fetch_page(store.scraper_module, path) do
      {:ok, %{status: 200, body: body}} ->
        store_event(url, body, store)

      {:ok, %{status: status}} ->
        Logger.info("EventPages: #{url} answered HTTP #{status}; skipping")
        {:skip, {:http, status}}

      {:error, reason} ->
        Logger.info("EventPages: fetch of #{url} failed (#{inspect(reason)}); skipping")
        {:skip, reason}
    end
  end

  defp store_event(url, body, store) do
    structured = body |> EventExtractor.events() |> List.first()

    attrs = %{
      store_id: store.id,
      title: (structured && structured.title) || title_of(body, url),
      event_date: (structured && structured.event_date) || date_of(body),
      description: structured && structured.description,
      location: structured && structured.location,
      url: url,
      scraped_at: DateTime.utc_now()
    }

    case Events.upsert_event(attrs) do
      {:ok, event} ->
        Logger.info("EventPages: stored \"#{event.title}\" from #{url}")
        {:ok, event}

      {:error, changeset} ->
        Logger.warning("EventPages: refused #{url}: #{inspect(changeset.errors)}")
        {:skip, :invalid}
    end
  end

  @doc """
  The event's title, from the page's own `<title>` element.

  Shopify titles carry the shop as a suffix — `"Treive Nicholas book signing at our Sea Point
  store — Wordsworth Books"` — so everything from the last em/en dash separator is dropped. Falls
  back to the slug, humanised, because a page whose `<title>` is missing still has a name in its
  URL and "Untitled" would be an invented fact.
  """
  @spec title_of(String.t(), String.t()) :: String.t()
  def title_of(body, url) do
    with [_, raw] <- Regex.run(~r/<title[^>]*>([^<]+)<\/title>/i, body),
         cleaned = raw |> strip_shop_suffix() |> String.trim(),
         false <- cleaned == "" do
      cleaned
    else
      _ ->
        url
        |> String.trim_trailing("/")
        |> String.split("/")
        |> List.last()
        |> String.replace("-", " ")
        |> String.capitalize()
    end
  end

  defp strip_shop_suffix(title) do
    case Regex.split(~r/\s+[—–|]\s+/u, title) do
      [only] -> only
      parts -> parts |> Enum.drop(-1) |> Enum.join(" — ")
    end
  end

  @doc """
  The event's date, only when the page states exactly one distinct ISO date.

  The same rule `parse_events/2` earned: several different dates cannot be attributed without the
  surrounding DOM, and attributing one anyway manufactures a confident, wrong record. One page, one
  distinct date, is the only unambiguous case. Returns `nil` otherwise — including for the real
  page, which states no date at all.
  """
  @spec date_of(String.t()) :: DateTime.t() | nil
  def date_of(body) do
    dates =
      ~r/(\d{4}-\d{2}-\d{2})/
      |> Regex.scan(body)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()

    case dates do
      [single] ->
        case DateTime.from_iso8601("#{single}T00:00:00Z") do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp client, do: Application.get_env(:core, :scraper_client, Stacks.Enrichment.ScraperClient)
end
