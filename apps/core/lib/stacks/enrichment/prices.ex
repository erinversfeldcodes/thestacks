defmodule Stacks.Enrichment.Prices do
  @moduledoc """
      Price enrichment — scraped price snapshots for editions across bookstores.

      Snapshots are keyed on `(book_edition_id, store_id)` and upserted per scrape.
      A price is a fact about an EDITION, not a work: shops stock specific ISBNs at
      different prices, so all staleness and lookups are per edition.
  """

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment
  alias Stacks.Enrichment.{Bookstore, PriceSnapshot}
  alias Stacks.Workers.TriggerPriceScrapeJob

  @doc """
      Upserts the snapshot for a `(book_edition_id, store_id)` pair.

      `book_id` is derived here from the edition and must NOT be supplied: the
      schema carries both columns (proto field numbers are forever), and deriving
      at the single write site keeps them from disagreeing.
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
      Prices for a work, refreshing stale ones in the background — the read path
      that replaced the nightly sweep, so outbound load tracks reader interest.
      Returns held snapshots immediately; refreshes land on later reads.
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
      Editions not priced in the last `days` days, as
      `%{isbn:, book_id:, book_edition_id:}` maps. Staleness is judged PER
      EDITION — a fresh snapshot for one edition must not mask its siblings.
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
      Records what a store was OBSERVED to be capable of. Capability is derived,
      never declared: shops replatform, and the scraper reports observations on
      every response so a replatform surfaces on the next scrape.
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
      Records that robots.txt blocks `path`, with the responsible rule — a block
      is observable state, not a silent skip. The store's configuration stays in
      place so a lifted disallow resumes on its own (see `clear_robots_block/1`).
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
      Clears a store's robots block after a successful fetch — the half that makes
      blocks self-healing. No-op when none is recorded, so call it unconditionally
      on success.
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
      Notes a successfully-priced ISBN as the store's canary. Capability detection
      only notices when detected values CHANGE; the canary catches the subtler
      failure where the platform looks the same but lookups quietly stop resolving.
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
      Reacts to the canary no longer resolving: clears the derived capability so
      the next scrape re-derives it. Does nothing for non-canary ISBNs — an
      ordinary edition going out of stock is normal.
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
      Stores the scraper service can actually be asked about — those with a
      `scraper_module` registry key naming a TOML config (base URL, selectors,
      rate limit). A store without one answers `404 store not found`; use this,
      never `all_stores/0`, for anything that fetches.
  """
  @spec scrapeable_stores() :: [Bookstore.t()]
  def scrapeable_stores do
    Repo.all(from b in Bookstore, where: not is_nil(b.scraper_module))
  end
end
