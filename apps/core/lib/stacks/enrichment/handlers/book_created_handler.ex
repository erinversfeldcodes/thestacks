defmodule Stacks.Enrichment.Handlers.BookCreatedHandler do
  @moduledoc """
  Event handler for the enrichment a newly created book implies.

  Listens for `book.created` events and enqueues the enrichment a new book implies:
  a price scrape for its ISBN, and author-source discovery for a small number of
  authors still missing theirs.

  ## Why discovery is triggered here

  `DiscoverAuthorSourcesJob`'s nightly batch was the only thing that ever ran it, and
  `op.discovered_sources` has never held a row. That job *creates* rather than
  refreshes, so a cron entry that may not fire — the platform scales to zero — means
  the feature has never existed, not that it is stale.

  A per-book enqueue is what the nightly batch originally replaced, because it
  exhausted Brave Search's free tier within hours. That is no longer the same risk:
  `BraveClient` now enforces a hard 200/day budget internally, so no trigger can
  overspend it. The batch here is deliberately tiny anyway — work should arrive in
  proportion to catalogue growth, which is what creates the need, rather than in bursts.
  """

  @behaviour Stacks.Events.Handler

  alias Stacks.Enrichment.Authors
  alias Stacks.Workers.DiscoverAuthorSourcesJob
  alias Stacks.Workers.DiscoverEditionsJob
  alias Stacks.Workers.TriggerPriceScrapeJob

  require Logger

  @impl true
  def handle_event(%{event_type: "book.created", payload: payload, aggregate_id: book_id}) do
    isbn = Map.get(payload, "isbn") || Map.get(payload, :isbn)

    if isbn do
      Logger.info("BookCreatedHandler: enqueuing price scrape for isbn=#{isbn} book=#{book_id}")

      enqueue_author_discovery()
      enqueue_edition_discovery(book_id)

      # Only the ISBN is passed. A price belongs to an edition, and the ISBN *is*
      # the edition's natural key, so the job resolves it — sending `book_id`
      # would name a work that may have many ISBNs and could not say which one
      # was priced.
      case %{isbn: isbn}
           |> TriggerPriceScrapeJob.new()
           |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "BookCreatedHandler: failed to enqueue price scrape for isbn=#{isbn}: #{inspect(reason)}"
          )

          :ok
      end
    else
      Logger.debug("BookCreatedHandler: no ISBN in book.created payload, skipping")
      :ok
    end
  end

  def handle_event(_event), do: :ok

  # Authors to attempt per new book. Small on purpose: the point is a trickle
  # proportional to catalogue growth, not a burst. Deduplicated per author, so a busy
  # day does not enqueue the same author repeatedly.
  @authors_per_book 2

  # Editions are discovered per *work*, so this is keyed by book_id rather than ISBN —
  # the opposite of the price job above, and for the same reason stated there: a price
  # is a fact about one edition, whereas the edition list is a fact about the work.
  #
  # Deduplicated for a day: a work's edition list on Open Library does not change on the
  # timescale of a book being added twice, and re-running would spend the creation cap
  # rediscovering rows that already exist.
  defp enqueue_edition_discovery(book_id) do
    %{book_id: book_id}
    |> DiscoverEditionsJob.new(unique: [period: 86_400, fields: [:worker, :args]])
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "BookCreatedHandler: failed to enqueue edition discovery for book=#{book_id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp enqueue_author_discovery do
    Authors.authors_without_sources()
    |> Enum.take(@authors_per_book)
    |> Enum.each(fn author ->
      %{author_id: author.id}
      |> DiscoverAuthorSourcesJob.new(unique: [period: 86_400, fields: [:worker, :args]])
      |> Oban.insert()
    end)
  rescue
    error ->
      # Never fail a book creation over enrichment scheduling.
      Logger.warning("BookCreatedHandler: could not enqueue author discovery: #{inspect(error)}")
      :ok
  end
end
