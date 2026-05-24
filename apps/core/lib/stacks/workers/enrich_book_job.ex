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

  # Aggressive early backoff. Default Oban backoff is
  # `(attempt - 1) ** 4 + 15 + (rand * 30)` seconds — attempt 2 lands at
  # 15-45 s after attempt 1, which routinely exceeds the upload UI's
  # 60 s enrichment-poll budget when OL/GB are transiently slow. Our
  # cache-poison fix means a transient resolver error no longer locks
  # the ISBN out for an hour, so retrying fast is safe. Stair-step
  # 3 → 6 → 12 → 24 s gets attempt 4 in by ~45 s, fitting comfortably
  # inside the test poll while still ceiling at 48 s on attempt 5.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    case attempt do
      1 -> 3
      2 -> 6
      3 -> 12
      4 -> 24
      _ -> 48
    end
  end

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
      with {:ok, author} <- Books.find_or_create_author(metadata[:author]),
           {:ok, _} <- update_book(book, metadata, author),
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

  # Bug-fix history: previous versions cast only `title` and
  # `description` from the resolver metadata. The resolver returns
  # `author` as a string (e.g. `"Umberto Eco"`), but `op.books` stores it
  # as `author_id` (FK to `op.authors`), so the author silently vanished
  # on enrichment — placeholder books ended up with a real title but
  # `author: null` in the API. The fix runs `find_or_create_author/1` in
  # the transaction and links the resulting row via `author_id`. When the
  # resolver has no author (nil/empty), we leave the existing `author_id`
  # alone rather than null it out.
  defp update_book(%Book{} = book, metadata, author) do
    base = %{
      "title" => presence_or(metadata[:title], book.title),
      "description" => presence_or(metadata[:description], book.description)
    }

    attrs =
      case author do
        nil -> base
        %{id: id} -> Map.put(base, "author_id", id)
      end

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
