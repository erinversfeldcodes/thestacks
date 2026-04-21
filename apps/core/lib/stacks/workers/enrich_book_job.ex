defmodule Stacks.Workers.EnrichBookJob do
  @moduledoc """
  Oban worker that fills in external-registry metadata (title, author,
  cover, publisher, etc.) for a book previously stored with placeholder
  fields.

  Invoked by `Stacks.Moderation.store_book/3` when a checksum-valid ISBN
  arrives from the vision pipeline — that fast path skips the synchronous
  OpenLibrary/Google Books lookup to cut ~400ms from the upload hot path,
  so this worker picks up the round-trip asynchronously.

  Behaviour:
    * Looks up the book by ISBN (not by ID — the Moderation pipeline
      deduplicates via `Books.find_existing(isbn)`, so the same ISBN
      may already have been enriched by a prior run; we re-fetch the
      latest row every time).
    * Calls `Books.resolve_isbn/1` which hits the cached + parallel
      OL/GB resolver. Any miss is logged and retried by Oban.
    * Updates the book row in-place, overwriting the placeholder
      title/author/cover/etc. with real metadata.
    * No-ops when the book already has a real title (not starting with
      the `"ISBN "` placeholder) — another run already enriched it.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Books.BookEdition

  @placeholder_title_prefix "ISBN "

  @impl true
  def perform(%Oban.Job{args: %{"isbn" => isbn}}) when is_binary(isbn) do
    case Books.find_existing(isbn) do
      nil ->
        Logger.info("EnrichBookJob: no book row for ISBN #{isbn} yet — skipping")
        :ok

      %Book{title: title} = _book when is_binary(title) and title != "" ->
        if already_enriched?(title) do
          Logger.debug("EnrichBookJob: book for ISBN #{isbn} already enriched — skipping")
          :ok
        else
          enrich(isbn)
        end

      %Book{} ->
        enrich(isbn)
    end
  end

  # Legacy arg shape — pre-consolidation jobs carried `book_id`. ISBN
  # lives on `BookEdition`, not `Book`, so we need a join to recover it.
  def perform(%Oban.Job{args: %{"book_id" => book_id}}) do
    # Schema maps `inserted_at` → `created_at` column; sort by the real
    # column name to recover the oldest edition deterministically.
    isbn_query =
      from e in BookEdition,
        where: e.book_id == ^book_id,
        order_by: [asc: e.created_at],
        limit: 1,
        select: e.isbn

    case Repo.one(isbn_query) do
      nil ->
        Logger.warning("EnrichBookJob: no edition (and thus no ISBN) for book #{book_id}")
        :ok

      isbn when is_binary(isbn) and isbn != "" ->
        perform(%Oban.Job{args: %{"isbn" => isbn}})

      _ ->
        :ok
    end
  end

  defp already_enriched?(title) do
    not String.starts_with?(title, @placeholder_title_prefix)
  end

  defp enrich(isbn) do
    case Books.resolve_isbn(isbn) do
      {:ok, metadata} ->
        apply_metadata(isbn, metadata)

      {:error, reason} ->
        Logger.warning(
          "EnrichBookJob: ISBN #{isbn} resolution failed (#{inspect(reason)}); will retry"
        )

        {:error, reason}
    end
  end

  defp apply_metadata(isbn, metadata) do
    case Books.find_existing(isbn) do
      nil ->
        Logger.info("EnrichBookJob: book for ISBN #{isbn} vanished between lookup + update")
        :ok

      %Book{} = book ->
        # Fields split across Book (title/description/subjects) and
        # BookEdition (cover/publisher/publication_year/page_count) —
        # update both rows in a single transaction so the user sees
        # enriched metadata atomically rather than a half-filled row.
        Repo.transaction(fn ->
          update_book(book, metadata)
          update_primary_edition(isbn, metadata)
        end)
        |> case do
          {:ok, _} ->
            Logger.info("EnrichBookJob: enriched ISBN #{isbn} with metadata")
            :ok

          {:error, reason} ->
            Logger.warning("EnrichBookJob: update failed for ISBN #{isbn}: #{inspect(reason)}")
            {:error, :update_failed}
        end
    end
  end

  defp update_book(%Book{} = book, metadata) do
    attrs = %{
      "title" => metadata[:title] || book.title,
      "description" => metadata[:description] || book.description
    }

    book
    |> Books.book_changeset(attrs)
    |> Repo.update!()
  end

  defp update_primary_edition(isbn, metadata) do
    case Repo.one(from e in BookEdition, where: e.isbn == ^isbn, limit: 1) do
      nil ->
        :ok

      edition ->
        attrs = %{
          "cover_image_url" => metadata[:cover_image_url] || edition.cover_image_url,
          "publisher" => metadata[:publisher] || edition.publisher,
          "publication_year" => metadata[:publication_year] || edition.publication_year,
          "page_count" => metadata[:page_count] || edition.page_count
        }

        edition
        |> Books.book_edition_changeset(attrs)
        |> Repo.update!()
    end
  end
end
