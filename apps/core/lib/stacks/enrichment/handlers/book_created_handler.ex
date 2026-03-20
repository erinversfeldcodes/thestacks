defmodule Stacks.Enrichment.Handlers.BookCreatedHandler do
  @moduledoc """
  Event handler that auto-triggers price scraping when a new book is created.

  Listens for `book.created` events and enqueues a `TriggerPriceScrapeJob`
  for the book's ISBN.
  """

  @behaviour Stacks.Events.Handler

  alias Stacks.Workers.TriggerPriceScrapeJob

  require Logger

  @impl true
  def handle_event(%{event_type: "book.created", payload: payload, aggregate_id: book_id}) do
    isbn = Map.get(payload, "isbn") || Map.get(payload, :isbn)

    if isbn do
      Logger.info("BookCreatedHandler: enqueuing price scrape for isbn=#{isbn} book=#{book_id}")

      %{isbn: isbn, book_id: book_id}
      |> TriggerPriceScrapeJob.new()
      |> Oban.insert()

      :ok
    else
      Logger.debug("BookCreatedHandler: no ISBN in book.created payload, skipping")
      :ok
    end
  end

  def handle_event(_event), do: :ok
end
