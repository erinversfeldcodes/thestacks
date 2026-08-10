defmodule Stacks.Workers.GoodreadsImportJob do
  @moduledoc """
  Works through a library import's rows in batches of #{25}, writing each row's
  outcome, then re-enqueues itself for the next batch until the rows are
  exhausted — a 600-row library becomes 24 short jobs instead of one long one,
  so a deploy or crash loses at most a batch of progress, never the import.

  Retry safety rests on two facts:

    * every row's `outcome` is written as it is processed, and a row with an
      outcome is **skipped** on re-run — so a batch that dies halfway resumes
      where it stopped, and the unique `[import_id, row_number]` index means a
      row can never be duplicated;
    * a resolver outage (`:resolver_unavailable`) fails the WHOLE batch with
      `{:error, …}` so Oban retries it with backoff. The hard gate's rule: an
      upstream that did not answer said nothing about the book, so the row must
      not be marked `unverified` — that word is reserved for ISBNs the upstreams
      actually rejected. Only on the final exhausted attempt does the import
      itself go `failed`, with every processed row's outcome intact.

  Rows that fail the gate get an outcome and a `reason` the reader can act on
  (`unverified` — no/unknown ISBN; `duplicate` — already on a bookshelf;
  `unreadable` — the CSV row itself was malformed). Placements are created via
  `Shelving.place_book/5` with `source: "goodreads_import"`, which both records
  provenance and suppresses per-placement feed regeneration —
  `Stacks.Imports.finalize/2` returns the touched bookshelves and this job
  enqueues ONE `RegenerateFeedJob` per bookshelf at the end.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:import_id, :offset], period: 300]

  require Logger

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.ISBN
  alias Stacks.Imports
  alias Stacks.Imports.GoodreadsCsv
  alias Stacks.Imports.LibraryImportRow
  alias Stacks.Shelving
  alias Stacks.Workers.RegenerateFeedJob

  import Ecto.Query

  @batch_size 25

  @impl true
  def perform(%Oban.Job{
        args: %{"import_id" => import_id, "offset" => offset},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case Repo.get(Stacks.Imports.LibraryImport, import_id) do
      nil ->
        {:cancel, "import no longer exists"}

      %{status: status} when status in ["complete", "failed"] ->
        {:cancel, "import already #{status}"}

      import ->
        import
        |> Imports.mark_running()
        |> run_batch(offset, attempt >= max_attempts)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("GoodreadsImportJob: unexpected args shape: #{inspect(args)}")
    {:cancel, "invalid args"}
  end

  defp run_batch(import, offset, final_attempt?) do
    batch = next_batch(import.id, offset)

    case process_batch(import, batch) do
      :ok when batch == [] ->
        finish(import, "complete")

      :ok ->
        Imports.refresh_processed_count(import)
        enqueue_next(import.id, List.last(batch).row_number)

      {:error, :resolver_unavailable} when final_attempt? ->
        # The gate never converts an outage into "unverified"; the import
        # fails instead, with every already-processed row's outcome kept.
        Logger.error(
          "GoodreadsImportJob: resolver still unavailable on final attempt, " <>
            "failing import=#{import.id} at offset=#{offset}"
        )

        finish(import, "failed")

      {:error, :resolver_unavailable} ->
        {:error, "ISBN resolver unavailable — retrying batch at offset #{offset}"}
    end
  end

  defp next_batch(import_id, offset) do
    LibraryImportRow
    |> where([r], r.import_id == ^import_id and r.row_number > ^offset)
    |> order_by([r], asc: r.row_number)
    |> limit(^@batch_size)
    |> Repo.all()
  end

  defp process_batch(import, batch) do
    Enum.reduce_while(batch, :ok, fn row, :ok ->
      case process_row(import, row) do
        :ok -> {:cont, :ok}
        {:error, :resolver_unavailable} -> {:halt, {:error, :resolver_unavailable}}
      end
    end)
  end

  # Already processed (this batch is a retry) — skip, never redo.
  defp process_row(_import, %LibraryImportRow{outcome: outcome}) when not is_nil(outcome), do: :ok

  defp process_row(import, row) do
    with {:ok, isbn} <- usable_isbn(row),
         {:ok, bookshelf_name} <- destination(row),
         {:ok, book, edition_id} <- find_or_create_book(isbn) do
      shelve(import, row, book, edition_id, bookshelf_name)
    else
      {:unverified, reason} ->
        Imports.record_outcome(row, "unverified", reason: reason)
        :ok

      {:unreadable, reason} ->
        Imports.record_outcome(row, "unreadable", reason: reason)
        :ok

      {:error, :resolver_unavailable} ->
        {:error, :resolver_unavailable}
    end
  end

  # The hard gate's front door: no verifiable ISBN, no entry. Goodreads rows for
  # ebooks/audiobooks often ship without one — the reader's report says so
  # plainly instead of inventing a book.
  defp usable_isbn(row) do
    # canonical_isbn13/1 normalises but does NOT validate (an empty cell comes
    # back as ""), and valid_isbn_checksum?/1 deliberately fails OPEN for
    # strings not shaped like an ISBN — so the gate here demands both: 13
    # digits AND a passing checksum. ISBN13 preferred, ISBN10 accepted
    # (canonicalised to 13).
    candidate =
      Enum.find_value([row.raw_isbn13, row.raw_isbn], fn raw ->
        canonical = ISBN.canonical_isbn13(raw)

        if is_binary(canonical) and canonical =~ ~r/^\d{13}$/ and
             ISBN.valid_isbn_checksum?(canonical),
           do: canonical
      end)

    case candidate do
      nil -> {:unverified, "no valid ISBN in the export row — books cannot enter unverified"}
      isbn -> {:ok, isbn}
    end
  end

  defp destination(row) do
    case GoodreadsCsv.destination_bookshelf(row) do
      nil ->
        {:unreadable, "unrecognised Goodreads shelf #{inspect(row.goodreads_shelf)}"}

      bookshelf_name ->
        {:ok, bookshelf_name}
    end
  end

  defp find_or_create_book(isbn) do
    case Books.find_existing_edition(isbn) do
      %{book: book} = edition ->
        {:ok, book, edition.id}

      nil ->
        case Books.create_from_isbn(isbn) do
          {:ok, book} ->
            {:ok, book, nil}

          {:error, :isbn_not_found} ->
            {:unverified, "ISBN #{isbn} not found on Open Library or Google Books"}

          {:error, :resolver_unavailable} ->
            {:error, :resolver_unavailable}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:unverified, "book record rejected: #{inspect(changeset.errors)}"}
        end
    end
  end

  defp shelve(import, row, book, edition_id, bookshelf_name) do
    if duplicate?(import.user_id, book.id, bookshelf_name) do
      Imports.record_outcome(row, "duplicate",
        reason: "already on your #{bookshelf_name} bookshelf",
        book_id: book.id
      )

      :ok
    else
      case Shelving.place_book(import.user_id, book.id, bookshelf_name, edition_id,
             source: "goodreads_import",
             attrs: carried_attrs(row, bookshelf_name)
           ) do
        {:ok, placement} ->
          Imports.record_outcome(row, "shelved", book_id: book.id, placement_id: placement.id)
          :ok

        {:error, :reading_pile_full} ->
          # The pile's 50-book cap holds for imports too; the book is real, the
          # pile is full — report it rather than silently rerouting.
          Imports.record_outcome(row, "unverified",
            reason: "reading pile is full — move some books and re-import",
            book_id: book.id
          )

          :ok

        {:error, %Ecto.Changeset{} = changeset} ->
          Imports.record_outcome(row, "duplicate",
            reason: "placement rejected: #{inspect(changeset.errors)}",
            book_id: book.id
          )

          :ok
      end
    end
  end

  defp duplicate?(user_id, book_id, bookshelf_name) do
    user_id
    |> Shelving.get_placements_for_book(book_id)
    |> Enum.any?(&(&1.bookshelf.name == bookshelf_name))
  end

  # The reader's Goodreads history, carried onto the placement it maps to.
  defp carried_attrs(row, bookshelf_name) do
    %{}
    |> put_if(:personal_rating, if(row.raw_rating in 1..5, do: row.raw_rating))
    |> put_if(:notes, carried_notes(row))
    |> put_if(
      :formats,
      row.raw_binding |> GoodreadsCsv.format_for() |> List.wrap() |> non_empty()
    )
    |> put_if(:placed_at, parse_goodreads_date(row.raw_date_added))
    |> Map.merge(reading_attrs(row, bookshelf_name))
  end

  defp reading_attrs(row, "library") do
    %{reading_status: "completed"}
    |> put_if(:finished_at, parse_goodreads_date(row.raw_date_read))
  end

  defp reading_attrs(_row, "reading_pile"), do: %{reading_status: "reading"}
  defp reading_attrs(_row, _), do: %{reading_status: "to_read"}

  defp carried_notes(row) do
    [row.raw_review, row.raw_notes]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  # Goodreads exports dates as `YYYY/MM/DD`.
  defp parse_goodreads_date(value) do
    with <<_::binary>> <- value,
         [y, m, d] <- String.split(value, "/"),
         {:ok, date} <- Date.new(int!(y), int!(m), int!(d)),
         {:ok, dt} <- DateTime.new(date, ~T[00:00:00]) do
      dt
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp int!(s), do: String.to_integer(s)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp enqueue_next(import_id, offset) do
    case %{"import_id" => import_id, "offset" => offset} |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, "failed to enqueue next batch: #{inspect(reason)}"}
    end
  end

  defp finish(import, status) do
    {:ok, bookshelves} = Imports.finalize(import, status)

    Enum.each(bookshelves, fn bookshelf_name ->
      case %{user_id: import.user_id, bookshelf_name: bookshelf_name}
           |> RegenerateFeedJob.new()
           |> Oban.insert() do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "GoodreadsImportJob: failed to enqueue feed regeneration for " <>
              "#{bookshelf_name}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end
end
