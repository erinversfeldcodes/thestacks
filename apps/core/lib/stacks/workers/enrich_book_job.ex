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
    result = Books.resolve_isbn(isbn)

    :telemetry.execute(
      [:stacks, :enrichment, :resolver, :outcome],
      %{count: 1},
      %{isbn: isbn, outcome: outcome_tag(result), source: source_tag(result)}
    )

    case result do
      {:ok, metadata} ->
        apply_metadata(isbn, metadata)

      {:error, reason} ->
        Logger.warning(
          "EnrichBookJob: ISBN #{isbn} resolution failed (#{inspect(reason)}); will retry"
        )

        {:error, reason}
    end
  end

  # Classify the resolver result into a closed tag set so that
  # log/telemetry consumers (and the diagnostic tests in
  # enrichment_diagnostics_test.exs) can distinguish each failure mode
  # observed in production: cache poisoning (:not_found), blown fuses
  # (:circuit_open), unexpected 5xx (:unexpected_status), malformed JSON
  # (:malformed_response), transport failure (:transport_error), and
  # outright timeout (:timeout). No catch-all — every atom in
  # `Stacks.Books.ISBNResolver.error_reason()` has a matching clause so
  # dialyzer rejects any new resolver reason that goes unmapped here.
  defp outcome_tag({:ok, _}), do: :ok
  defp outcome_tag({:error, :not_found}), do: :not_found
  defp outcome_tag({:error, :circuit_open}), do: :circuit_open
  defp outcome_tag({:error, :unexpected_status}), do: :unexpected_status
  defp outcome_tag({:error, :malformed_response}), do: :malformed_response
  defp outcome_tag({:error, :transport_error}), do: :transport_error
  defp outcome_tag({:error, :timeout}), do: :timeout

  defp source_tag({:ok, %{source: source}}), do: source
  defp source_tag(_), do: nil

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
        #
        # Bug-fix history: previous versions used Repo.update!/1 here.
        # A raise inside the transaction propagated out, Oban retried
        # the job 5×, every retry hit the same bug, and the job was
        # silently abandoned — leaving the book stuck on its
        # placeholder title for an hour. Both helpers now return
        # `{:ok, struct}` / `{:error, changeset}` and we propagate
        # failure via Repo.rollback/1 so the transaction surfaces a
        # tidy `{:error, _}` instead of a process-leaking raise.
        book
        |> run_update_transaction(isbn, metadata)
        |> handle_update_result(isbn)
    end
  end

  defp run_update_transaction(book, isbn, metadata) do
    Repo.transaction(fn ->
      with {:ok, _} <- update_book(book, metadata),
           {:ok, _} <- update_primary_edition(isbn, metadata) do
        :ok
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp handle_update_result({:ok, _}, isbn) do
    Logger.info("EnrichBookJob: enriched ISBN #{isbn} with metadata")
    :ok
  end

  defp handle_update_result({:error, %Ecto.Changeset{errors: errors}}, isbn) do
    Logger.warning("EnrichBookJob: update failed for ISBN #{isbn}: #{inspect(errors)}")
    {:error, :update_failed}
  end

  defp handle_update_result({:error, reason}, isbn) do
    Logger.warning("EnrichBookJob: update failed for ISBN #{isbn}: #{inspect(reason)}")
    {:error, :update_failed}
  end

  defp update_book(%Book{} = book, metadata) do
    attrs = %{
      "title" => presence_or(metadata[:title], book.title),
      "description" => presence_or(metadata[:description], book.description)
    }

    book
    |> Books.book_changeset(attrs)
    |> Repo.update()
  end

  defp update_primary_edition(isbn, metadata) do
    case Repo.one(from e in BookEdition, where: e.isbn == ^isbn, limit: 1) do
      nil ->
        {:ok, nil}

      edition ->
        attrs = %{
          "cover_image_url" => metadata[:cover_image_url] || edition.cover_image_url,
          "publisher" => metadata[:publisher] || edition.publisher,
          "publication_year" =>
            coerce_integer(metadata[:publication_year]) || edition.publication_year,
          "page_count" => coerce_integer(metadata[:page_count]) || edition.page_count
        }

        edition
        |> Books.book_edition_changeset(attrs)
        |> Repo.update()
    end
  end

  # Treat blank or whitespace-only strings as absent so we fall back to
  # the existing column value. Without this, OL responses carrying
  # `"title": ""` would replace a real placeholder with an empty title,
  # tripping `validate_required(:title)` on book_changeset.
  defp presence_or(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      _ -> value
    end
  end

  defp presence_or(nil, fallback), do: fallback
  defp presence_or(value, _fallback), do: value

  # Coerce values destined for `:integer` Ecto fields. OL and Google
  # Books occasionally return `page_count` / `publish_date` as strings
  # (`"lots"`, `"unknown"`, `"200"`); a non-coercible value would fail
  # the changeset cast and (with the old `Repo.update!`) raise out of
  # the transaction. Returning `nil` here lets the `||` fallback in the
  # caller keep the existing column value.
  defp coerce_integer(value) when is_integer(value), do: value

  defp coerce_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp coerce_integer(_), do: nil
end
