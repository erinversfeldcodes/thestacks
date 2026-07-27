defmodule Stacks.Enrichment.Prices do
  @moduledoc """
  Context for price enrichment — manages scraped price snapshots for editions
  across bookstores.

  Price snapshots are keyed on `(book_edition_id, store_id)` and upserted on each
  scrape run. `stale_isbns/1` identifies editions that need a fresh scrape.

  ## Why the edition, not the work

  A price is a fact about an *edition*. Shops stock whichever edition they stock,
  at different prices — Exclusive Books carries six ISBNs of The Name of the Rose,
  two of them Spanish, from R400 to R411. Keying on the work made those six
  indistinguishable.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment
  alias Stacks.Enrichment.{Bookstore, PriceSnapshot}

  # ── Snapshots ─────────────────────────────────────────────────────────────

  @doc """
  Inserts a new price snapshot or updates the existing one for the same
  `(book_edition_id, store_id)` pair.

  `book_id` is **derived here** from the edition and must not be supplied by the
  caller. The schema carries both columns because proto field numbers are forever
  and `buf breaking` is FILE-strict, so `book_id` cannot be removed — but two
  columns describing the same relationship can disagree, and deriving it at the
  single write site is what makes disagreement unrepresentable rather than merely
  discouraged.

  Returns `{:ok, snapshot}`, `{:error, changeset}`, or `{:error, :unknown_edition}`
  when `book_edition_id` names no edition.
  """
  @spec upsert_snapshot(map()) ::
          {:ok, PriceSnapshot.t()} | {:error, Ecto.Changeset.t()} | {:error, :unknown_edition}
  def upsert_snapshot(attrs) do
    case attrs["book_edition_id"] || attrs[:book_edition_id] do
      nil ->
        # Nothing supplied: report it through the changeset like any other missing
        # required field, so callers have one error shape for validation problems.
        # `:unknown_edition` is reserved for an id that was given but names nothing —
        # a different situation deserving a different answer.
        {:error, Enrichment.price_snapshot_changeset(%PriceSnapshot{}, attrs)}

      edition_id ->
        case derive_book_id(edition_id) do
          {:ok, book_id} ->
            %PriceSnapshot{}
            |> Enrichment.price_snapshot_changeset(put_book_id(attrs, book_id))
            |> Repo.insert(
              on_conflict: {:replace, [:price_cents, :currency, :in_stock, :url, :scraped_at]},
              conflict_target: [:book_edition_id, :store_id],
              # Without this, an upsert that hit an existing row returns the struct
              # we *sent* — including a freshly generated id that is not the stored
              # one. Callers would see every upsert as an insert.
              returning: true
            )

          :error ->
            {:error, :unknown_edition}
        end
    end
  end

  defp derive_book_id(edition_id) do
    case Repo.one(from(be in BookEdition, where: be.id == ^edition_id, select: be.book_id)) do
      nil -> :error
      book_id -> {:ok, book_id}
    end
  end

  # Mirror the key style the caller used so a string-keyed changeset doesn't end
  # up with one atom key (Ecto's cast would silently drop the mixed one).
  defp put_book_id(attrs, book_id) when is_map_key(attrs, :book_edition_id),
    do: Map.put(attrs, :book_id, book_id)

  defp put_book_id(attrs, book_id), do: Map.put(attrs, "book_id", book_id)

  @doc """
  Returns the latest price snapshot per store for every edition of the given work.

  Callers hold a work (that is what a book-detail page shows), while prices hang
  off editions — so the join is part of the read, not the caller's problem.
  """
  @spec latest_prices(String.t()) :: [PriceSnapshot.t()]
  def latest_prices(book_id) do
    PriceSnapshot
    |> join(:inner, [ps], be in BookEdition, on: be.id == ps.book_edition_id)
    |> where([_ps, be], be.book_id == ^book_id)
    |> order_by([ps], desc: ps.scraped_at)
    |> Repo.all()
  end

  @doc """
  Returns editions that have not been priced in the last `days` days.

  Returns a list of `%{isbn: isbn, book_id: book_id, book_edition_id: id}` maps.

  The join is on `book_edition_id`, per edition. It used to join on `book_id`,
  which meant a fresh snapshot for **one** edition made **every** edition of that
  work look freshly scraped — so on a work with six editions, five could never be
  priced at all. The staleness question is per edition because the price is.
  """
  @spec stale_isbns(non_neg_integer()) :: [
          %{isbn: String.t(), book_id: String.t(), book_edition_id: String.t()}
        ]
  def stale_isbns(days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(be in BookEdition,
      left_join: ps in PriceSnapshot,
      on: ps.book_edition_id == be.id,
      where: is_nil(ps.id) or ps.scraped_at < ^cutoff,
      select: %{isbn: be.isbn, book_id: be.book_id, book_edition_id: be.id},
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
