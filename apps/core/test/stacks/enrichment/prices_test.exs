defmodule Stacks.Enrichment.PricesTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Enrichment.Prices

  describe "upsert_snapshot/1" do
    test "inserts a new price snapshot" do
      book = insert(:book)
      store = insert(:bookstore)

      attrs = %{
        book_id: book.id,
        store_id: store.id,
        price_cents: 29_900,
        currency: "ZAR",
        in_stock: true,
        url: "https://example.com/book",
        scraped_at: DateTime.utc_now()
      }

      assert {:ok, snapshot} = Prices.upsert_snapshot(attrs)
      assert snapshot.price_cents == 29_900
      assert snapshot.book_id == book.id
      assert snapshot.store_id == store.id
    end

    test "updates existing snapshot on conflict (same book_id + store_id)" do
      book = insert(:book)
      store = insert(:bookstore)
      now = DateTime.utc_now()

      attrs = %{
        book_id: book.id,
        store_id: store.id,
        price_cents: 29_900,
        currency: "ZAR",
        in_stock: true,
        url: "https://example.com/book",
        scraped_at: now
      }

      assert {:ok, _} = Prices.upsert_snapshot(attrs)

      updated_attrs = %{attrs | price_cents: 19_900, in_stock: false}
      assert {:ok, updated} = Prices.upsert_snapshot(updated_attrs)
      assert updated.price_cents == 19_900
      assert updated.in_stock == false
    end

    test "returns error changeset for missing required fields" do
      assert {:error, changeset} = Prices.upsert_snapshot(%{})
      assert errors_on(changeset) |> Map.has_key?(:book_id)
      assert errors_on(changeset) |> Map.has_key?(:price_cents)
      assert errors_on(changeset) |> Map.has_key?(:scraped_at)
    end

    test "validates price_cents is non-negative" do
      book = insert(:book)
      store = insert(:bookstore)

      attrs = %{
        book_id: book.id,
        store_id: store.id,
        price_cents: -100,
        scraped_at: DateTime.utc_now()
      }

      assert {:error, changeset} = Prices.upsert_snapshot(attrs)
      assert errors_on(changeset) |> Map.has_key?(:price_cents)
    end
  end

  describe "latest_prices/1" do
    test "returns price snapshots for the given book" do
      book = insert(:book)
      store1 = insert(:bookstore)
      store2 = insert(:bookstore)

      insert(:price_snapshot, book: book, store: store1, price_cents: 10_000)
      insert(:price_snapshot, book: book, store: store2, price_cents: 20_000)

      prices = Prices.latest_prices(book.id)
      assert length(prices) == 2
    end

    test "returns empty list for book with no snapshots" do
      book = insert(:book)
      assert Prices.latest_prices(book.id) == []
    end
  end

  describe "stale_isbns/1" do
    test "returns ISBNs for books not scraped recently" do
      book = insert(:book)
      _edition = insert(:book_edition, book: book, isbn: "9780743273565")

      stale = Prices.stale_isbns(7)
      assert Enum.any?(stale, fn entry -> entry.isbn == "9780743273565" end)
    end

    test "excludes books scraped within the window" do
      book = insert(:book)
      store = insert(:bookstore)
      _edition = insert(:book_edition, book: book, isbn: "9780743273565")

      insert(:price_snapshot,
        book: book,
        store: store,
        scraped_at: DateTime.utc_now()
      )

      stale = Prices.stale_isbns(7)
      refute Enum.any?(stale, fn entry -> entry.isbn == "9780743273565" end)
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
end
