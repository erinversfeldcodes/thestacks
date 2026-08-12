defmodule Stacks.Workers.EnrichBookJob do
  @moduledoc """
      Fills in external-registry metadata for a book stored with placeholder
      fields — the async half of the fast path where `Moderation.store_book/3`
      skips the synchronous OL/GB lookup (~400ms off the upload hot path).
      Looks up by ISBN, not ID (the pipeline dedups via `find_existing/1`, so
      a prior run may already have enriched the row); calls
      `Books.resolve_isbn/1` (cached, parallel); overwrites placeholders
      in place. Emits `book.enriched` so caches invalidate.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

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
  alias Stacks.Events

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

  def perform(%Oban.Job{args: %{"book_id" => book_id}}) do
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
        book
        |> run_update_transaction(isbn, metadata)
        |> handle_update_result(isbn)
        |> announce_enrichment(book)
    end
  end

  defp announce_enrichment(:ok, %Book{} = book) do
    Events.emit_safe(%{
      event_type: "book.enriched",
      aggregate_type: "book",
      aggregate_id: book.id,
      payload: %{book_id: book.id},
      metadata: %{actor: "enrich_book_job"}
    })

    :ok
  end

  defp announce_enrichment(other, _book), do: other

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
          "page_count" => coerce_integer(metadata[:page_count]) || edition.page_count,
          "open_library_id" => metadata[:open_library_id] || edition.open_library_id,
          "google_books_id" => metadata[:google_books_id] || edition.google_books_id,
          "verification_source" => Books.verification_source_from(metadata)
        }

        edition
        |> Books.book_edition_changeset(attrs)
        |> Repo.update()
    end
  end

  defp presence_or(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      _ -> value
    end
  end

  defp presence_or(nil, fallback), do: fallback
  defp presence_or(value, _fallback), do: value

  defp coerce_integer(value) when is_integer(value), do: value

  defp coerce_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp coerce_integer(_), do: nil
end
