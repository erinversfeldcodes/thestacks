defmodule Stacks.Workers.DiscoverEditionsJob do
  @moduledoc """
  Discovers other editions of a work from Open Library and records them.

  A work is the abstract book; an edition is a printing with its own ISBN. Shops stock
  whichever edition they stock, so without this a price lookup can only ever ask about
  the one ISBN a reader happened to type. Exclusive Books carries six ISBNs of *The
  Name of the Rose*, two of them Spanish — pricing the work means knowing they exist.

  Triggered from `book.created` rather than a cron: this **creates** rather than
  refreshes, and a cron that creates is the defect that left `discovered_sources` empty
  for months (campaign ROOT H). Work should arrive in proportion to catalogue growth.

  ## Two different caps, for two different budgets

  `ISBNResolver.editions_for_work/1` caps the *fetch* at 50, protecting Open Library
  from an unbounded page walk. This job caps *creation* at ten, protecting our own
  budget: `Books.merge_edition/2` re-resolves each ISBN to honour the ISBN hard gate, so
  fifty merges is fifty resolver races on a first-time book.

  Ten is chosen against the consumer, not picked round: `Prices.enqueue_refreshes/1`
  prices at most five editions per work, so ten gives the price layer more choice than
  it can use while keeping the cost per new book bounded. Discovering fifty editions to
  price five would be work nobody collects.
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
