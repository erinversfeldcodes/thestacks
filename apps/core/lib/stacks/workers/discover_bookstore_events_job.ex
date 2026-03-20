defmodule Stacks.Workers.DiscoverBookstoreEventsJob do
  @moduledoc """
  Oban worker that discovers events at bookstores by scraping their websites.

  Accepts `%{"store_id" => id}` for a single bookstore, or `%{"batch" => true}`
  to process all bookstores with a `website_url` set.

  For each store, fetches the events page, parses event data, and links to
  known authors when an author name matches the event title or description.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Books.Author
  alias Stacks.Enrichment.{Events, Prices}

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
    stores =
      Prices.all_stores()
      |> Enum.filter(& &1.website_url)

    Logger.info("DiscoverBookstoreEventsJob: processing #{length(stores)} stores in batch")

    Enum.each(stores, &discover_for_store/1)

    :ok
  end

  defp discover_for_store(store) do
    events_url = build_events_url(store.website_url)

    case fetch_page(events_url) do
      {:ok, body} ->
        events = parse_events(body, store)
        persist_events(events, store)

      {:error, reason} ->
        Logger.warning(
          "DiscoverBookstoreEventsJob: fetch failed for store #{store.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc false
  def build_events_url(website_url) do
    base = String.trim_trailing(website_url, "/")
    "#{base}/events"
  end

  defp fetch_page(url) do
    req = Finch.build(:get, url, [{"Accept", "text/html"}])

    case Finch.request(req, Stacks.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("DiscoverBookstoreEventsJob: fetch_page failed: #{Exception.message(e)}")
      {:error, {:request_failed, Exception.message(e)}}
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
