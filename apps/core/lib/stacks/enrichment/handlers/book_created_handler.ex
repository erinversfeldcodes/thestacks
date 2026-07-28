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
  alias Stacks.Workers.TriggerPriceScrapeJob

  require Logger

  @impl true
  def handle_event(%{event_type: "book.created", payload: payload, aggregate_id: book_id}) do
    isbn = Map.get(payload, "isbn") || Map.get(payload, :isbn)

    if isbn do
      Logger.info("BookCreatedHandler: enqueuing price scrape for isbn=#{isbn} book=#{book_id}")

      enqueue_author_discovery()

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
