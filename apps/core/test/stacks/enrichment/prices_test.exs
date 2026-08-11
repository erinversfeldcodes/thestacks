defmodule Stacks.Enrichment.PricesTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Enrichment.Prices

  describe "upsert_snapshot/1" do
    test "inserts a snapshot against the edition and derives the work" do
      edition = insert(:book_edition)
      store = insert(:bookstore)

      attrs = %{
        book_edition_id: edition.id,
        store_id: store.id,
        price_cents: 29_900,
        currency: "ZAR",
        in_stock: true,
        url: "https://example.com/book",
        scraped_at: DateTime.utc_now()
      }

      assert {:ok, snapshot} = Prices.upsert_snapshot(attrs)
      assert snapshot.price_cents == 29_900
      assert snapshot.book_edition_id == edition.id
      assert snapshot.store_id == store.id
      assert snapshot.book_id == edition.book_id
    end

    test "ignores a caller-supplied book_id rather than letting it contradict the edition" do
      edition = insert(:book_edition)
      other_book = insert(:book)
      store = insert(:bookstore)

      assert {:ok, snapshot} =
               Prices.upsert_snapshot(%{
                 book_edition_id: edition.id,
                 book_id: other_book.id,
                 store_id: store.id,
                 price_cents: 15_000,
                 scraped_at: DateTime.utc_now()
               })

      assert snapshot.book_id == edition.book_id
      refute snapshot.book_id == other_book.id
    end

    test "two editions of one work hold separate prices at the same store" do
      book = insert(:book)
      paperback = insert(:book_edition, book: book, isbn: "9780749397050")
      spanish = insert(:book_edition, book: book, isbn: "9788497592581", is_primary: false)
      store = insert(:bookstore)

      base = %{store_id: store.id, scraped_at: DateTime.utc_now()}

      assert {:ok, a} =
               Prices.upsert_snapshot(
                 Map.merge(base, %{book_edition_id: paperback.id, price_cents: 40_000})
               )

      assert {:ok, b} =
               Prices.upsert_snapshot(
                 Map.merge(base, %{book_edition_id: spanish.id, price_cents: 41_100})
               )

      refute a.id == b.id
      assert Enum.sort([a.price_cents, b.price_cents]) == [40_000, 41_100]
    end

    test "updates the existing snapshot for the same (edition, store)" do
      edition = insert(:book_edition)
      store = insert(:bookstore)

      attrs = %{
        book_edition_id: edition.id,
        store_id: store.id,
        price_cents: 29_900,
        currency: "ZAR",
        in_stock: true,
        scraped_at: DateTime.utc_now()
      }

      assert {:ok, first} = Prices.upsert_snapshot(attrs)

      assert {:ok, updated} =
               Prices.upsert_snapshot(%{attrs | price_cents: 19_900, in_stock: false})

      assert updated.id == first.id
      assert updated.price_cents == 19_900
      assert updated.in_stock == false
    end

    test "returns a changeset when no edition is supplied" do
      assert {:error, changeset} = Prices.upsert_snapshot(%{})
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :book_edition_id)
      assert Map.has_key?(errors, :price_cents)
      assert Map.has_key?(errors, :scraped_at)
    end

    test "returns :unknown_edition when the edition id names nothing" do
      store = insert(:bookstore)

      assert {:error, :unknown_edition} =
               Prices.upsert_snapshot(%{
                 book_edition_id: Ecto.UUID.generate(),
                 store_id: store.id,
                 price_cents: 10_000,
                 scraped_at: DateTime.utc_now()
               })
    end

    test "validates price_cents is non-negative" do
      edition = insert(:book_edition)
      store = insert(:bookstore)

      assert {:error, changeset} =
               Prices.upsert_snapshot(%{
                 book_edition_id: edition.id,
                 store_id: store.id,
                 price_cents: -100,
                 scraped_at: DateTime.utc_now()
               })

      assert errors_on(changeset) |> Map.has_key?(:price_cents)
    end
  end

  describe "latest_prices/1" do
    test "returns snapshots across every edition of the work" do
      book = insert(:book)
      paperback = insert(:book_edition, book: book, isbn: "9780749397050")
      spanish = insert(:book_edition, book: book, isbn: "9788497592581", is_primary: false)

      insert(:price_snapshot,
        book_edition: paperback,
        book: book,
        store: insert(:bookstore),
        price_cents: 40_000
      )

      insert(:price_snapshot,
        book_edition: spanish,
        book: book,
        store: insert(:bookstore),
        price_cents: 41_100
      )

      prices = Prices.latest_prices(book.id)
      assert length(prices) == 2
    end

    test "does not leak prices from another work" do
      book = insert(:book)
      other = insert(:book)
      other_edition = insert(:book_edition, book: other)

      insert(:price_snapshot,
        book_edition: other_edition,
        book: other,
        store: insert(:bookstore)
      )

      assert Prices.latest_prices(book.id) == []
    end
  end

  describe "stale_isbns/1" do
    test "returns editions that have never been priced" do
      book = insert(:book)
      _edition = insert(:book_edition, book: book, isbn: "9780743273565")

      stale = Prices.stale_isbns(7)
      entry = Enum.find(stale, &(&1.isbn == "9780743273565"))

      assert entry, "an unpriced edition must be reported stale"
      assert entry.book_id == book.id
      assert entry.book_edition_id
    end

    test "staleness is per edition: pricing one leaves its siblings stale" do
      book = insert(:book)
      priced = insert(:book_edition, book: book, isbn: "9780749397050")
      sibling = insert(:book_edition, book: book, isbn: "9788497592581", is_primary: false)

      insert(:price_snapshot,
        book_edition: priced,
        book: book,
        store: insert(:bookstore),
        scraped_at: DateTime.utc_now()
      )

      isbns = Prices.stale_isbns(7) |> Enum.map(& &1.isbn)

      refute priced.isbn in isbns, "the edition just priced should not be stale"

      assert sibling.isbn in isbns,
             "a sibling edition was never priced and must still be stale"
    end

    test "excludes an edition priced inside the window and includes one outside it" do
      book = insert(:book)
      fresh = insert(:book_edition, book: book, isbn: "9780743273565")
      old = insert(:book_edition, book: book, isbn: "9780156001311", is_primary: false)
      store = insert(:bookstore)

      insert(:price_snapshot,
        book_edition: fresh,
        book: book,
        store: store,
        scraped_at: DateTime.utc_now()
      )

      insert(:price_snapshot,
        book_edition: old,
        book: book,
        store: store,
        scraped_at: DateTime.add(DateTime.utc_now(), -30, :day)
      )

      isbns = Prices.stale_isbns(7) |> Enum.map(& &1.isbn)

      refute fresh.isbn in isbns
      assert old.isbn in isbns
    end
  end

  describe "all_stores/0" do
    test "returns all bookstores" do
      insert(:bookstore, name: "Store A")
      insert(:bookstore, name: "Store B")

      stores = Prices.all_stores()
      assert length(stores) >= 2
    end
  end

  describe "scrapeable_stores/0" do
    test "excludes stores with no scraper registry key" do
      addressable = insert(:bookstore, name: "Configured", scraper_module: "za/configured")
      orphan = insert(:bookstore, name: "No Config", scraper_module: nil)

      keys = Prices.scrapeable_stores() |> Enum.map(& &1.id)

      assert addressable.id in keys
      refute orphan.id in keys
    end

    test "every returned store has a non-nil registry key" do
      insert(:bookstore, scraper_module: nil)
      insert(:bookstore, scraper_module: "za/some_store")

      for store <- Prices.scrapeable_stores() do
        refute is_nil(store.scraper_module),
               "scrapeable_stores/0 returned an unaddressable store"
      end
    end
  end

  describe "record_capability/2" do
    test "records what was observed, with a timestamp" do
      store = insert(:bookstore, price_source: nil, isbn_location: nil, lookup_mode: nil)

      assert :ok =
               Prices.record_capability(store, %{
                 "price_source" => "shopify_products_json",
                 "isbn_location" => "handle",
                 "lookup_mode" => "direct"
               })

      reloaded = Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id)
      assert reloaded.price_source == "shopify_products_json"
      assert reloaded.isbn_location == "handle"
      assert reloaded.lookup_mode == "direct"
      assert reloaded.capability_probed_at
    end

    test "notices a replatform rather than trusting the stored platform" do
      store =
        insert(:bookstore,
          price_source: "woo_store_api",
          isbn_location: "sku",
          lookup_mode: "native_search",
          capability_probed_at: DateTime.utc_now()
        )

      assert :ok =
               Prices.record_capability(store, %{
                 "price_source" => "shopify_products_json",
                 "isbn_location" => "handle",
                 "lookup_mode" => "direct"
               })

      reloaded = Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id)
      assert reloaded.price_source == "shopify_products_json"
      assert reloaded.lookup_mode == "direct"
    end

    test "a response without a capability is not an error" do
      store = insert(:bookstore, price_source: "woo_store_api")

      assert :ok = Prices.record_capability(store, nil)

      assert Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).price_source ==
               "woo_store_api"
    end

    test "an unchanged observation inside the day does not churn the row" do
      store =
        insert(:bookstore,
          price_source: "shopify_products_json",
          isbn_location: "handle",
          lookup_mode: "direct",
          capability_probed_at: DateTime.utc_now()
        )

      before = Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).updated_at

      assert :ok =
               Prices.record_capability(store, %{
                 "price_source" => "shopify_products_json",
                 "isbn_location" => "handle",
                 "lookup_mode" => "direct"
               })

      assert Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).updated_at == before
    end

    test "an unchanged but stale observation refreshes its timestamp" do
      old = DateTime.add(DateTime.utc_now(), -10, :day)

      store =
        insert(:bookstore,
          price_source: "shopify_products_json",
          isbn_location: "handle",
          lookup_mode: "direct",
          capability_probed_at: old
        )

      assert :ok =
               Prices.record_capability(store, %{
                 "price_source" => "shopify_products_json",
                 "isbn_location" => "handle",
                 "lookup_mode" => "direct"
               })

      refreshed = Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).capability_probed_at
      assert DateTime.compare(refreshed, old) == :gt
    end
  end

  describe "canary" do
    test "a priced ISBN becomes the canary" do
      store = insert(:bookstore, canary_isbn: nil)
      assert :ok = Prices.note_canary(store, "9780749397050")

      assert Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).canary_isbn ==
               "9780749397050"
    end

    test "the canary going missing clears the capability so it is re-derived" do
      store =
        insert(:bookstore,
          canary_isbn: "9780749397050",
          price_source: "shopify_products_json",
          isbn_location: "handle",
          lookup_mode: "direct",
          capability_probed_at: DateTime.utc_now()
        )

      assert :ok = Prices.canary_failed(store, "9780749397050")

      reloaded = Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id)
      assert reloaded.price_source == nil
      assert reloaded.isbn_location == nil
      assert reloaded.lookup_mode == nil
      assert reloaded.capability_probed_at == nil
    end

    test "an ordinary edition going out of stock changes nothing" do
      store =
        insert(:bookstore,
          canary_isbn: "9780749397050",
          price_source: "shopify_products_json",
          isbn_location: "handle",
          lookup_mode: "direct"
        )

      assert :not_canary = Prices.canary_failed(store, "9788497592581")

      assert Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).price_source ==
               "shopify_products_json"
    end

    test "a store with no canary yet is unaffected" do
      store = insert(:bookstore, canary_isbn: nil, price_source: "woo_store_api")

      assert :not_canary = Prices.canary_failed(store, "9780749397050")

      assert Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).price_source ==
               "woo_store_api"
    end

    test "re-noting the same canary does not write" do
      store = insert(:bookstore, canary_isbn: "9780749397050")
      before = Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).updated_at

      assert :ok = Prices.note_canary(store, "9780749397050")

      assert Core.Repo.get!(Stacks.Enrichment.Bookstore, store.id).updated_at == before
    end
  end
end
