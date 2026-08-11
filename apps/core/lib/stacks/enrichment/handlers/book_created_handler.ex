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

  @authors_per_book 2

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
      Logger.warning("BookCreatedHandler: could not enqueue author discovery: #{inspect(error)}")
      :ok
  end
end
