defmodule Stacks.Books.Handlers.CacheInvalidationHandler do
  @moduledoc """
  Evicts `BookDetailCache` entries when the thing that cache holds changes.

  What it holds is `Stacks.Books.get_book_detail/1` — an `%Book{}` with its
  `:author` and `:editions` preloaded — keyed by **work id**. So the only
  question this handler ever asks of an event is *which work did that change?*,
  and the answer is not always `aggregate_id`.

  Handles `book.created`, `book.cover_confirmed`, `books.edition_merged`,
  `book.visibility_tier_changed`, `book.enriched` and
  `blog.associations_suggested`.

  ## Where the work id comes from, and why it differs per event

  `book.created` aggregates the work, so `aggregate_id` IS the cache key.

  `book.visibility_tier_changed` and `book.enriched` also aggregate the work, so
  `aggregate_id` would happen to work for them — and they still read the payload,
  because "the aggregate happens to be the cache key" is exactly the assumption
  described below.

  The other three aggregate something else — an edition, an edition, a blog post
  — and carry the work id in the payload. Reading `aggregate_id` for those is a
  key that can never be in the cache, so the eviction silently does nothing:
  exactly the `book.cover_confirmed` defect found while fixing #355, where the
  handler evicted under an *edition* id and a confirmed cover stayed invisible
  for the full 5-minute TTL. The handler's own test passed throughout, because
  it built the event by hand with a book id in `aggregate_id` — a shape
  `confirm_cover_association/2` has never emitted.

  Payload keys arrive as strings in production (the event is read back out of
  `event_log`'s jsonb by `SubscriberWorker`) and as atoms when a handler is
  called directly, so every lookup accepts both.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Books.BookDetailCache

  @impl true
  def handle_event(%{event_type: "book.created", aggregate_id: book_id}) do
    BookDetailCache.invalidate(book_id)
    :ok
  end

  # The age gate moved on the WORK (#357). `Books.set_visibility_tier/3` has
  # already evicted the entry synchronously by the time this runs — a raised gate
  # cannot wait for a queue — so this clause is not the primary route; it is what
  # makes the wire uniform and covers any other emitter of this type.
  def handle_event(%{event_type: "book.visibility_tier_changed", payload: payload}) do
    invalidate_from_payload(payload, {"book_id", :book_id}, "book.visibility_tier_changed")
  end

  # `Stacks.Workers.EnrichBookJob` rewrote the work's title/description/author and
  # its primary edition's cover in one transaction, then named the work here
  # (#357). Unlike the age gate above, this IS the only eviction route — the
  # freshness of a title is worth a queue hop.
  def handle_event(%{event_type: "book.enriched", payload: payload}) do
    invalidate_from_payload(payload, {"book_id", :book_id}, "book.enriched")
  end

  # aggregate_type "book_edition": the cover was confirmed on an EDITION, and
  # the work it belongs to is in the payload.
  def handle_event(%{event_type: "book.cover_confirmed", payload: payload}) do
    invalidate_from_payload(payload, {"book_id", :book_id}, "book.cover_confirmed")
  end

  # aggregate_type "book_edition" again: `merge_edition/2` aggregates the new
  # edition and names the work it was merged into as `work_id`.
  def handle_event(%{event_type: "books.edition_merged", payload: payload}) do
    invalidate_from_payload(payload, {"work_id", :work_id}, "books.edition_merged")
  end

  def handle_event(%{event_type: "blog.associations_suggested", payload: payload}) do
    book_ids = Map.get(payload, "book_ids") || Map.get(payload, :book_ids, [])

    Enum.each(book_ids, &BookDetailCache.invalidate/1)
    :ok
  end

  def handle_event(_event), do: :ok

  # A payload missing its work id is a contract break, not a reason to crash the
  # dispatch: log it and let the TTL do the job the eviction should have. Loud
  # enough to be found, quiet enough not to retry a handler that can never
  # succeed for this row.
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
