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
        {:error, Enrichment.price_snapshot_changeset(%PriceSnapshot{}, attrs)}

      edition_id ->
        case derive_book_id(edition_id) do
          {:ok, book_id} ->
            %PriceSnapshot{}
            |> Enrichment.price_snapshot_changeset(put_book_id(attrs, book_id))
            |> Repo.insert(
              on_conflict: {:replace, [:price_cents, :currency, :in_stock, :url, :scraped_at]},
              conflict_target: [:book_edition_id, :store_id],
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
    Application.get_env(:core, :lazy_price_refresh, true)
  end

  @max_editions_per_refresh 5

  defp enqueue_refreshes(book_id, prices, ttl_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_days, :day)

    fresh_edition_ids =
      prices
      |> Enum.filter(&(DateTime.compare(&1.scraped_at, cutoff) == :gt))
      |> MapSet.new(& &1.book_edition_id)

    from(be in BookEdition,
      where: be.book_id == ^book_id,
      order_by: [desc: be.is_primary, asc: be.isbn],
      select: %{id: be.id, isbn: be.isbn}
    )
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(fresh_edition_ids, &1.id))
    |> Enum.take(@max_editions_per_refresh)
    |> Enum.each(fn edition ->
      %{isbn: edition.isbn, book_edition_id: edition.id}
      |> TriggerPriceScrapeJob.new(unique: [period: 3600, fields: [:worker, :args]])
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

      stale_observation?(store) ->
        update_store(store, attrs)

      true ->
        :ok
    end
  end

  @doc """
  Record that robots.txt blocks `path` for this store, with the rule responsible.

  A block is **observable state**, not a silent skip. Before this existed the column
  was present and nothing wrote it, so a store forbidden by robots.txt looked
  identical to one that simply had no prices yet — and an operator had no way to learn
  which, or why.

  Per the owner's rule the store's configuration is deliberately left in place, so if
  the disallow is ever lifted the store resumes by itself. `robots_blocked_at` is what
  makes that re-checkable: the block is a dated observation, not a verdict.

  Returns `:ok` regardless — recording a block must never be what turns a handled
  determination into a failure.
  """
  @spec record_robots_block(map(), String.t(), String.t()) :: :ok
  def record_robots_block(store, path, rule) do
    if store.robots_blocked_path == path and store.robots_blocked_rule == rule do
      update_store(store, %{robots_blocked_at: DateTime.utc_now()})
    else
      Logger.warning(
        "Prices: #{store.name} blocked by robots.txt at #{path} (#{rule}) — " <>
          "configuration retained so it resumes if the rule is lifted"
      )

      update_store(store, %{
        robots_blocked_path: path,
        robots_blocked_rule: rule,
        robots_blocked_at: DateTime.utc_now()
      })
    end
  end

  @doc """
  Clear a store's robots block after a successful fetch.

  The other half of `record_robots_block/3`, and the half that makes the block
  self-healing: without it, a disallow lifted next month would leave the store
  permanently marked as blocked, and "re-checked on the probe cadence" would be a
  claim with nothing behind it.

  A no-op when no block is recorded, so callers can call it unconditionally on success
  rather than checking first — the error case is defined out of existence.
  """
  @spec clear_robots_block(map()) :: :ok
  def clear_robots_block(%{robots_blocked_path: nil}), do: :ok

  def clear_robots_block(store) do
    Logger.info(
      "Prices: #{store.name} is no longer blocked by robots.txt " <>
        "(was #{store.robots_blocked_path}, #{store.robots_blocked_rule}) — resuming"
    )

    update_store(store, %{
      robots_blocked_path: nil,
      robots_blocked_rule: nil,
      robots_blocked_at: nil
    })
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
        Logger.warning(
          "Prices: could not record capability for #{store.name}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  @doc """
  Note that an ISBN priced successfully at this store, keeping it as the canary.

  ## Why a canary at all

  Capability detection notices a replatform only when the *detected* values change.
  It cannot notice the subtler failure: the platform stays Shopify, the probe still
  answers, but the shop's theme moves the ISBN out of `handle` for new products, or
  re-slugs its catalogue. Detection reports the same capability while every lookup
  quietly returns "not stocked".

  A canary closes that: an ISBN we have *actually priced here* must keep resolving.
  When it stops, the capability is suspect regardless of what detection says, so it
  is cleared and re-derived on the next scrape rather than trusted.

  Only set when absent or when it changes, so this costs no write on the common path.
  """
  @spec note_canary(Bookstore.t(), String.t()) :: :ok
  def note_canary(%{canary_isbn: isbn}, isbn), do: :ok

  def note_canary(store, isbn) when is_binary(isbn) do
    store
    |> Ecto.Changeset.change(%{canary_isbn: isbn})
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  def note_canary(_store, _isbn), do: :ok

  @doc """
  React to the canary failing to resolve.

  The store still answers and its platform still looks the same, but an ISBN we
  previously priced here no longer resolves — so what we believe about this store is
  no longer supported by evidence. Clearing the capability forces the next scrape to
  re-derive it instead of continuing to use a mapping that has stopped working.

  Deliberately does nothing when the ISBN is not the canary: an ordinary edition
  going out of stock is normal and says nothing about the store.
  """
  @spec canary_failed(Bookstore.t(), String.t()) :: :ok | :not_canary
  def canary_failed(%{canary_isbn: canary} = store, isbn)
      when canary == isbn and is_binary(canary) do
    Logger.warning(
      "Prices: canary #{canary} stopped resolving at #{store.name} — " <>
        "clearing observed capability so it is re-derived"
    )

    store
    |> Ecto.Changeset.change(%{
      price_source: nil,
      isbn_location: nil,
      lookup_mode: nil,
      capability_probed_at: nil
    })
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  def canary_failed(_store, _isbn), do: :not_canary

  @doc """
  Stores that must be matched by title because no product carries an ISBN.

  `isbn_location == "none"` with a working product API: the shop can be enumerated but
  its products cannot be identified by ISBN, so titles are the only handle. Measured
  for Ike's Books (0 of 50 products) and Love Books (0 of 30).
  """
  @spec stores_needing_title_match() :: [Bookstore.t()]
  def stores_needing_title_match do
    Repo.all(
      from b in Bookstore,
        where: b.isbn_location == "none" and not is_nil(b.scraper_module),
        where: not is_nil(b.price_source) and b.price_source != "none"
    )
  end

  @doc """
  Stores whose observed capability says they need a local ISBN index.

  Only stores that have actually been observed to need one. A store with no
  observation yet is excluded deliberately: its capability is derived on the next
  scrape, and sweeping a shop's whole catalogue on a guess is exactly the bulk
  harvesting this design avoids.
  """
  @spec stores_needing_index() :: [Bookstore.t()]
  def stores_needing_index do
    Repo.all(
      from b in Bookstore,
        where: b.lookup_mode == "local_index" and not is_nil(b.scraper_module),
        where: b.isbn_location != "none"
    )
  end

  @doc """
  Returns all bookstores.
  """
  @spec all_stores() :: [Bookstore.t()]
  def all_stores do
    Repo.all(Bookstore)
  end

  @doc """
  Stores the scraper service can actually be asked about.

  `scraper_module` is the scraper's **registry key** (`"za/exclusive_books"`), not a
  label — it names a TOML config that supplies the base URL, the selectors and the rate
  limit. A store without one cannot be addressed at all: the service answers
  `404 store not found`, and there is no fallback that could work.

  Exists because callers kept reaching for `all_stores/0` and then improvising. The
  worst improvisation was `store.scraper_module || store.name` in
  `TriggerPriceScrapeJob`, which substituted the **display name** ("Exclusive Books")
  for a registry key that is path-derived ("za/exclusive_books"). Those never match, so
  every ISBN × unconfigured-store pair produced a guaranteed 404 — and because the
  client melts a fuse on a non-200, a store nobody had configured could open the
  breaker for stores that were. The failure was silent in the sense that mattered:
  it looked like the shop was down.

  Filtering in the query rather than at each call site means a new caller gets this
  right by default instead of having to know.
  """
  @spec scrapeable_stores() :: [Bookstore.t()]
  def scrapeable_stores do
    Repo.all(from b in Bookstore, where: not is_nil(b.scraper_module))
  end
end
