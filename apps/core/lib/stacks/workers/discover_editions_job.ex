defmodule Stacks.Workers.DiscoverEditionsJob do
  @moduledoc """
  Discovers a work's other editions from Open Library — what lets a price
  lookup ask about the ISBNs shops actually stock, not just the one the
  reader typed. Triggered from `book.created`, not cron: this CREATES, and
  a cron that creates is the defect that left `discovered_sources` empty
  for months. Two caps for two budgets: the fetch caps at 50 (protecting
  OL), creation caps at 10 per work (protecting our own enrichment fan-out
  — each new edition triggers its own scrape). Discovered editions are
  recorded `verification_source: "open_library"`, never primary.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.BookEdition
  alias Stacks.Books.ISBNResolver

  import Ecto.Query

  @max_created_per_run 10

  @impl true
  def perform(%Oban.Job{args: %{"book_id" => book_id}}) do
    case primary_isbn(book_id) do
      nil ->
        Logger.debug("DiscoverEditionsJob: no primary edition for book=#{book_id}")
        :ok

      isbn ->
        discover(book_id, isbn)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("DiscoverEditionsJob: unexpected args shape: #{inspect(args)}")
    {:cancel, "invalid args"}
  end

  defp discover(book_id, isbn) do
    with {:ok, work_id} <- work_id_for(isbn),
         {:ok, isbns} <- ISBNResolver.editions_for_work(work_id) do
      created = create_editions(book_id, isbns, known_isbns(book_id))

      Logger.info(
        "DiscoverEditionsJob: book=#{book_id} work=#{work_id} " <>
          "offered=#{length(isbns)} created=#{created}"
      )

      :ok
    else
      {:error, :circuit_open} ->
        {:error, :circuit_open}

      {:error, reason} ->
        Logger.debug("DiscoverEditionsJob: no editions for book=#{book_id}: #{inspect(reason)}")

        :ok
    end
  end

  defp work_id_for(isbn) do
    case ISBNResolver.resolve(isbn) do
      {:ok, %{open_library_work_id: work_id}} when is_binary(work_id) and work_id != "" ->
        {:ok, work_id}

      {:ok, _no_work_key} ->
        {:error, :no_work_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_editions(book_id, isbns, known) do
    isbns
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.take(@max_created_per_run)
    |> Enum.reduce(0, fn isbn, created ->
      case Books.merge_edition(book_id, %{isbn: isbn}) do
        {:ok, _edition} ->
          created + 1

        {:error, reason} ->
          Logger.debug("DiscoverEditionsJob: skipped #{isbn}: #{inspect(reason)}")
          created
      end
    end)
  end

  defp known_isbns(book_id) do
    from(e in BookEdition, where: e.book_id == type(^book_id, Ecto.UUID), select: e.isbn)
    |> Repo.all()
    |> MapSet.new()
  end

  defp primary_isbn(book_id) do
    from(e in BookEdition,
      where: e.book_id == type(^book_id, Ecto.UUID) and e.is_primary == true,
      select: e.isbn,
      limit: 1
    )
    |> Repo.one()
  end
end
