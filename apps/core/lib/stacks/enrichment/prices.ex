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

  require Logger

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment
  alias Stacks.Enrichment.{Bookstore, PriceSnapshot}
  alias Stacks.Workers.TriggerPriceScrapeJob

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
  Prices for a work, refreshing any that are stale in the background.

  This is the read path, and it is what replaces the nightly sweep. The sweep was
  `stale_isbns(7) x all_stores()` with no cap — ~2,400 requests taking on the order
  of 20 hours against eleven mostly one-person bookshops, for prices nobody may
  ever look at. Fetching on read instead means outbound load tracks actual reader
  interest rather than catalogue size times wall clock.

  Returns immediately with whatever is already stored, stale or not: a price from
  last week is far more useful than a spinner, and the refreshed value appears on
  the next view. Enqueued work is deduplicated by Oban's `unique` option, so a
  popular book being viewed a hundred times does not enqueue a hundred scrapes.

  Rows carry the edition's ISBN and format and the store's name, not bare ids: the
  page groups prices by edition and names the shop, and resolving those per row in
  the view would be an N+1 the context can answer in one join.
  """
  @spec prices_for_work(String.t(), keyword()) :: [map()]
  def prices_for_work(book_id, opts \\ []) do
    ttl_days = Keyword.get(opts, :ttl_days, 7)
    prices = latest_prices(book_id)

    if refresh_enabled?() do
      enqueue_refreshes(book_id, prices, ttl_days)
    end

    from(ps in PriceSnapshot,
      join: be in BookEdition,
      on: be.id == ps.book_edition_id,
      left_join: bs in Bookstore,
      on: bs.id == ps.store_id,
      where: be.book_id == ^book_id,
      order_by: [asc: be.isbn, asc: ps.price_cents],
      select: %{
        book_edition_id: ps.book_edition_id,
        isbn: be.isbn,
        format_label: be.format_label,
        store_id: ps.store_id,
        store_name: bs.name,
        price_cents: ps.price_cents,
        currency: ps.currency,
        in_stock: ps.in_stock,
        url: ps.url,
        scraped_at: ps.scraped_at
      }
    )
    |> Repo.all()
  end

  defp refresh_enabled? do
    # Off in :test so reads do not enqueue jobs that tests must then account for;
    # a dedicated test sets it true to prove the enqueue actually happens.
    Application.get_env(:core, :lazy_price_refresh, true)
  end

  # Editions of this work that have no price, or a price older than the TTL.
  defp enqueue_refreshes(book_id, prices, ttl_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_days, :day)

    fresh_edition_ids =
      prices
      |> Enum.filter(&(DateTime.compare(&1.scraped_at, cutoff) == :gt))
      |> MapSet.new(& &1.book_edition_id)

    from(be in BookEdition,
      where: be.book_id == ^book_id,
      select: %{id: be.id, isbn: be.isbn}
    )
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(fresh_edition_ids, &1.id))
    |> Enum.each(fn edition ->
      %{isbn: edition.isbn, book_edition_id: edition.id}
      |> TriggerPriceScrapeJob.new(
        # One pending refresh per edition at a time. Without this a popular book
        # would enqueue a scrape on every page view.
        unique: [period: 3600, fields: [:worker, :args]]
      )
      |> Oban.insert()
    end)
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

  @doc """
  Record what a store was observed to be capable of.

  Capability is **derived, never declared**. Bookshops replatform — WooCommerce to
  Shopify, a theme change that moves the ISBN out of `sku` — and a hand-set platform
  turns that into a silent outage indistinguishable from "we don't stock it". The
  scraper reports what it observed on every response, so `capability_probed_at`
  stays current without a separate probe schedule and a replatform surfaces on the
  next scrape rather than the next sweep.

  Writes only when something actually changed, so an unchanged observation does not
  churn `updated_at` on every scrape. Returns `:ok` regardless: failing to record an
  observation must never fail the scrape that produced it.
  """
  @spec record_capability(Bookstore.t(), map() | nil) :: :ok
  def record_capability(_store, nil), do: :ok

  def record_capability(store, capability) when is_map(capability) do
    attrs = %{
      price_source: capability["price_source"],
      isbn_location: capability["isbn_location"],
      lookup_mode: capability["lookup_mode"],
      capability_probed_at: DateTime.utc_now()
    }

    changed? =
      store.price_source != attrs.price_source or
        store.isbn_location != attrs.isbn_location or
        store.lookup_mode != attrs.lookup_mode

    cond do
      changed? ->
        log_capability_change(store, attrs)
        update_store(store, attrs)

      # Refresh the timestamp periodically even when nothing changed, so a stale
      # `probed_at` genuinely means "not observed lately" rather than "unchanged".
      stale_observation?(store) ->
        update_store(store, attrs)

      true ->
        :ok
    end
  end

  defp log_capability_change(store, attrs) do
    Logger.info(
      "Prices: #{store.name} capability changed — " <>
        "source #{inspect(store.price_source)}→#{inspect(attrs.price_source)}, " <>
        "isbn_at #{inspect(store.isbn_location)}→#{inspect(attrs.isbn_location)}, " <>
        "lookup #{inspect(store.lookup_mode)}→#{inspect(attrs.lookup_mode)}"
    )
  end

  defp stale_observation?(%{capability_probed_at: nil}), do: true

  defp stale_observation?(%{capability_probed_at: at}) do
    DateTime.compare(at, DateTime.add(DateTime.utc_now(), -1, :day)) == :lt
  end

  defp update_store(store, attrs) do
    store
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        # Deliberately swallowed: an observation is a side-benefit of the scrape, and
        # losing it must not turn a successful price into a failure.
        Logger.warning(
          "Prices: could not record capability for #{store.name}: #{inspect(changeset.errors)}"
        )

        :ok
    end
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
