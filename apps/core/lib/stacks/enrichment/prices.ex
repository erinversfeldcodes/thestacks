defmodule Stacks.Enrichment.Prices do
  @moduledoc """
  Context for price enrichment — manages scraped price snapshots for books
  across bookstores.

  Price snapshots are keyed on `(book_id, store_id)` and upserted on each
  scrape run. The `stale_isbns/1` function identifies books that need a
  fresh scrape.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment
  alias Stacks.Enrichment.{Bookstore, PriceSnapshot}

  # ── Snapshots ─────────────────────────────────────────────────────────────

  @doc """
  Inserts a new price snapshot or updates the existing one for the same
  `(book_id, store_id)` pair.

  Returns `{:ok, snapshot}` on success, `{:error, changeset}` on validation failure.
  """
  @spec upsert_snapshot(map()) :: {:ok, PriceSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def upsert_snapshot(attrs) do
    %PriceSnapshot{}
    |> Enrichment.price_snapshot_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:price_cents, :currency, :in_stock, :url, :scraped_at]},
      conflict_target: [:book_id, :store_id]
    )
  end

  @doc """
  Returns the latest price snapshot per store for the given book_id.
  """
  @spec latest_prices(String.t()) :: [PriceSnapshot.t()]
  def latest_prices(book_id) do
    PriceSnapshot
    |> where([ps], ps.book_id == ^book_id)
    |> order_by([ps], desc: ps.scraped_at)
    |> Repo.all()
  end

  @doc """
  Returns ISBNs (from book_editions) for books that have not been scraped
  in the last `days` days. Joins books -> editions to get ISBNs with their
  book_ids.

  Returns a list of `%{isbn: isbn, book_id: book_id}` maps.
  """
  @spec stale_isbns(non_neg_integer()) :: [%{isbn: String.t(), book_id: String.t()}]
  def stale_isbns(days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(be in BookEdition,
      left_join: ps in PriceSnapshot,
      on: ps.book_id == be.book_id,
      where: is_nil(ps.id) or ps.scraped_at < ^cutoff,
      select: %{isbn: be.isbn, book_id: be.book_id},
      distinct: true
    )
    |> Repo.all()
  end

  # ── Stores ────────────────────────────────────────────────────────────────

  @doc """
  Returns all bookstores.
  """
  @spec all_stores() :: [Bookstore.t()]
  def all_stores do
    Repo.all(Bookstore)
  end
end
