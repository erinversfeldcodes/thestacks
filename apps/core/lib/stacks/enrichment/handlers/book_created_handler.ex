defmodule Stacks.Enrichment.Handlers.BookCreatedHandler do
  @moduledoc """
  Handler for `book.created`: enqueues a price scrape for the ISBN and a
  SMALL batch of author-source discovery. Discovery triggers here because
  the nightly batch alone never ran on a scale-to-zero platform —
  `op.discovered_sources` had never held a row. Per-book triggering used
  to exhaust Brave's free tier, but `BraveClient` now enforces a hard
  200/day budget internally, so no trigger can overspend; the batch is
  tiny so work arrives in proportion to catalogue growth.
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
