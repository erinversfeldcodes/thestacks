defmodule Stacks.Books.Handlers.CacheInvalidationHandler do
  @moduledoc """
      Evicts `BookDetailCache` entries (keyed by WORK id) when what they hold
      changes. Handles `book.created`, `book.cover_confirmed`,
      `books.edition_merged`, `book.visibility_tier_changed`, `book.enriched`,
      `blog.associations_suggested`.

      The only question asked of an event is "which work changed?" — and the
      answer is NOT always `aggregate_id`: three of these events aggregate
      something else (an edition, a blog post), so every handler reads the work
      id from the payload, even where the aggregate happens to coincide.
      `books.edition_merged` evicts BOTH works (the merged-away one may still
      be cached).
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Books.BookDetailCache

  @impl true
  def handle_event(%{event_type: "book.created", aggregate_id: book_id}) do
    BookDetailCache.invalidate(book_id)
    :ok
  end

  def handle_event(%{event_type: "book.visibility_tier_changed", payload: payload}) do
    invalidate_from_payload(payload, {"book_id", :book_id}, "book.visibility_tier_changed")
  end

  def handle_event(%{event_type: "book.enriched", payload: payload}) do
    invalidate_from_payload(payload, {"book_id", :book_id}, "book.enriched")
  end

  def handle_event(%{event_type: "book.cover_confirmed", payload: payload}) do
    invalidate_from_payload(payload, {"book_id", :book_id}, "book.cover_confirmed")
  end

  def handle_event(%{event_type: "books.edition_merged", payload: payload}) do
    invalidate_from_payload(payload, {"work_id", :work_id}, "books.edition_merged")
  end

  def handle_event(%{event_type: "blog.associations_suggested", payload: payload}) do
    book_ids = Map.get(payload, "book_ids") || Map.get(payload, :book_ids, [])

    Enum.each(book_ids, &BookDetailCache.invalidate/1)
    :ok
  end

  def handle_event(_event), do: :ok

  defp invalidate_from_payload(payload, {key, atom_key}, event_type) do
    case Map.get(payload, key) || Map.get(payload, atom_key) do
      nil ->
        Logger.warning(
          "CacheInvalidationHandler: #{event_type} payload has no #{key}; " <>
            "BookDetailCache not evicted (falling back to its TTL)"
        )

        :ok

      book_id ->
        BookDetailCache.invalidate(book_id)
        :ok
    end
  end
end
