defmodule Stacks.Imports do
  @moduledoc """
      Library imports: Goodreads CSV in, shelves out — through
      the same ISBN hard gate as every capture source. Import is a source, not
      a bypass: unverifiable rows land in the per-row report, not the system.
      `create_import/3` parses synchronously (format errors answered at upload
      time), persists import + rows, and enqueues `GoodreadsImportJob`, which
      writes each row's outcome (`shelved`/`duplicate`/`unverified`/
      `unreadable`). Raw rows are the reader's own free text: never in the
      warehouse (`skip_dbt`), swept after 30 days
      (`LibraryImportRowRetentionJob`); the import's counts survive as the
      durable summary. Rows are erasure-covered and export-included.
  """

  # Ecto.Multi's opaque internals trip dialyzer's call_without_opaque on every
  # chained call — the same known false positive Stacks.GDPR.Deletion documents.
  @dialyzer :no_opaque

  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Events
  alias Stacks.Imports.GoodreadsCsv
  alias Stacks.Imports.LibraryImport
  alias Stacks.Imports.LibraryImportRow
  alias Stacks.Workers.GoodreadsImportJob

  @active_statuses ~w(enqueued running)
  @row_retention_days 30
  @insert_chunk 500

  @doc "How long raw import rows are kept before the retention sweep deletes them."
  @spec row_retention_days() :: pos_integer()
  def row_retention_days, do: @row_retention_days

  @doc """
      Parses a Goodreads CSV export and creates the import with all its rows,
      enqueueing the processing job. Returns:

        * `{:ok, import}` — parsed, persisted, job enqueued
        * `{:error,:import_in_progress}` — the user already has an active import
        * `{:error,:unrecognised_format, headers}` — not a Goodreads export
        * `{:error,:no_rows}` — a header with nothing under it
  """
  @spec create_import(binary(), String.t(), binary()) ::
          {:ok, LibraryImport.t()}
          | {:error, :import_in_progress}
          | {:error, :unrecognised_format, [String.t()]}
          | {:error, :no_rows}
  def create_import(user_id, filename, csv_binary) do
    with :ok <- check_no_active_import(user_id),
         {:ok, rows} <- GoodreadsCsv.parse(csv_binary) do
      insert_import(user_id, filename, rows)
    end
  end

  defp check_no_active_import(user_id) do
    active =
      LibraryImport
      |> where([i], i.user_id == ^user_id and i.status in @active_statuses)
      |> Repo.exists?()

    if active, do: {:error, :import_in_progress}, else: :ok
  end

  defp insert_import(user_id, filename, rows) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.insert(:import, %LibraryImport{
      user_id: user_id,
      source: "goodreads",
      filename: filename,
      status: "enqueued",
      row_count: length(rows)
    })
    |> Multi.run(:rows, fn repo, %{import: import} ->
      rows
      |> Enum.map(&Map.merge(&1, %{import_id: import.id, created_at: now}))
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.each(&repo.insert_all(LibraryImportRow, &1))

      {:ok, length(rows)}
    end)
    |> Multi.run(:event, fn _repo, %{import: import} ->
      Events.emit_safe(%{
        event_type: "library_import.started",
        aggregate_type: "library_import",
        aggregate_id: import.id,
        payload: %{user_id: user_id, source: import.source, row_count: import.row_count}
      })

      {:ok, :emitted}
    end)
    |> Oban.insert(:job, fn %{import: import} ->
      GoodreadsImportJob.new(%{"import_id" => import.id, "offset" => 0})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{import: import}} -> {:ok, import}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Fetches an import scoped to its owner."
  @spec get_import(binary(), binary()) :: LibraryImport.t() | nil
  def get_import(user_id, id) do
    LibraryImport
    |> where([i], i.user_id == ^user_id and i.id == ^id)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "The user's imports, newest first."
  @spec list_imports(binary()) :: [LibraryImport.t()]
  def list_imports(user_id) do
    LibraryImport
    |> where([i], i.user_id == ^user_id)
    |> order_by([i], desc: i.created_at)
    |> Repo.all()
  end

  @doc """
      The per-row report for an import, scoped to its owner; `outcome:` narrows to
      one outcome (the "what didn't make it" view). Rows may already be gone —
      the retention sweep deletes them after #{@row_retention_days} days — so an
      empty list against a non-zero `row_count` means expired, not lost.
  """
  @spec list_rows(binary(), binary(), keyword()) ::
          {:ok, [LibraryImportRow.t()]} | {:error, :not_found}
  def list_rows(user_id, import_id, opts \\ []) do
    case get_import(user_id, import_id) do
      nil ->
        {:error, :not_found}

      import ->
        query =
          LibraryImportRow
          |> where([r], r.import_id == ^import.id)
          |> order_by([r], asc: r.row_number)

        query =
          case Keyword.get(opts, :outcome) do
            nil -> query
            outcome -> where(query, [r], r.outcome == ^outcome)
          end

        {:ok, Repo.all(query)}
    end
  end

  @doc "Marks an import running and stamps `started_at` (first batch only)."
  @spec mark_running(LibraryImport.t()) :: LibraryImport.t()
  def mark_running(%LibraryImport{status: "enqueued"} = import) do
    import
    |> Ecto.Changeset.change(status: "running", started_at: DateTime.utc_now())
    |> Repo.update!()
  end

  def mark_running(import), do: import

  @doc "Writes a row's outcome (and any resolved book/placement ids)."
  @spec record_outcome(LibraryImportRow.t(), String.t(), keyword()) :: LibraryImportRow.t()
  def record_outcome(%LibraryImportRow{} = row, outcome, opts \\ []) do
    row
    |> Ecto.Changeset.change(
      outcome: outcome,
      reason: Keyword.get(opts, :reason),
      book_id: Keyword.get(opts, :book_id),
      placement_id: Keyword.get(opts, :placement_id)
    )
    |> Repo.update!()
  end

  @doc "Refreshes `processed_count` from the rows table (single source of truth)."
  @spec refresh_processed_count(LibraryImport.t()) :: :ok
  def refresh_processed_count(%LibraryImport{id: import_id}) do
    processed =
      LibraryImportRow
      |> where([r], r.import_id == ^import_id and not is_nil(r.outcome))
      |> Repo.aggregate(:count)

    LibraryImport
    |> where([i], i.id == ^import_id)
    |> Repo.update_all(set: [processed_count: processed, updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
      Finalises an import: aggregates outcome counts from the rows (idempotent —
      re-running recomputes the same numbers), stamps the terminal status, and emits
      `library_import.completed`. Returns the bookshelf names that gained books, so
      the caller can enqueue ONE feed regeneration per bookshelf instead of one per
      placement.
  """
  @spec finalize(LibraryImport.t(), String.t()) :: {:ok, [String.t()]}
  def finalize(%LibraryImport{} = import, status) when status in ["complete", "failed"] do
    counts =
      LibraryImportRow
      |> where([r], r.import_id == ^import.id and not is_nil(r.outcome))
      |> group_by([r], r.outcome)
      |> select([r], {r.outcome, count(r.id)})
      |> Repo.all()
      |> Map.new()

    import =
      import
      |> Ecto.Changeset.change(
        status: status,
        finished_at: DateTime.utc_now(),
        processed_count: counts |> Map.values() |> Enum.sum(),
        shelved_count: Map.get(counts, "shelved", 0),
        duplicate_count: Map.get(counts, "duplicate", 0),
        unverified_count: Map.get(counts, "unverified", 0),
        unreadable_count: Map.get(counts, "unreadable", 0)
      )
      |> Repo.update!()

    Events.emit_safe(%{
      event_type: "library_import.completed",
      aggregate_type: "library_import",
      aggregate_id: import.id,
      payload: %{
        user_id: import.user_id,
        source: import.source,
        status: import.status,
        row_count: import.row_count,
        shelved_count: import.shelved_count,
        duplicate_count: import.duplicate_count,
        unverified_count: import.unverified_count,
        unreadable_count: import.unreadable_count
      }
    })

    {:ok, touched_bookshelves(import.id)}
  end

  defp touched_bookshelves(import_id) do
    LibraryImportRow
    |> where([r], r.import_id == ^import_id and r.outcome == "shelved")
    |> select([r], %{goodreads_shelf: r.goodreads_shelf, raw_owned_copies: r.raw_owned_copies})
    |> Repo.all()
    |> Enum.map(&GoodreadsCsv.destination_bookshelf/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
      Deletes raw rows older than #{@row_retention_days} days (GDPR §data-minimisation:
      the reviews/notes in a raw row serve the one-time report, not the platform).
      Returns the number deleted.
  """
  @spec delete_expired_rows() :: non_neg_integer()
  def delete_expired_rows do
    cutoff = DateTime.add(DateTime.utc_now(), -@row_retention_days, :day)

    {deleted, _} =
      LibraryImportRow
      |> where([r], r.created_at < ^cutoff)
      |> Repo.delete_all()

    deleted
  end
end
