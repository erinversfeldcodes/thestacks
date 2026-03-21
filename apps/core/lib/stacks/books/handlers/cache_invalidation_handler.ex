defmodule Stacks.Books.Handlers.CacheInvalidationHandler do
  @moduledoc """
  Event handler that invalidates `BookDetailCache` entries when book data changes.

  Handles `book.created`, `book.cover_confirmed`, and `blog.associations_suggested`.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Books.BookDetailCache

  @impl true
  def handle_event(%{event_type: "book.created", aggregate_id: book_id}) do
    BookDetailCache.invalidate(book_id)
    :ok
  end

  def handle_event(%{event_type: "book.cover_confirmed", aggregate_id: book_id}) do
    BookDetailCache.invalidate(book_id)
    :ok
  end

  def handle_event(%{event_type: "blog.associations_suggested", payload: payload}) do
    book_ids = Map.get(payload, "book_ids") || Map.get(payload, :book_ids, [])

    Enum.each(book_ids, &BookDetailCache.invalidate/1)
    :ok
  end

  def handle_event(_event), do: :ok
end
