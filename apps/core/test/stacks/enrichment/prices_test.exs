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
      # Derived, not supplied — the caller never sent a book_id.
      assert snapshot.book_id == edition.book_id
    end

    test "ignores a caller-supplied book_id rather than letting it contradict the edition" do
      # The two columns describe one relationship, so a caller must not be able to
      # make them disagree. Passing a wrong work id must not produce a row that
      # says edition E belongs to work W when it does not.
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
      # The point of the re-key. Exclusive Books stocks six ISBNs of The Name of
      # the Rose at different prices; the old (book_id, store_id) uniqueness made
      # the second one overwrite the first.
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
      # Distinct from the changeset case above: an id was given, it just does not
      # resolve. Collapsing the two would hide a broken producer behind a
      # validation error.
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
      # Callers hold a work — that is what a book-detail page shows — while prices
      # hang off editions, so the read must span them.
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
      # This is the defect the re-key fixes, and it was silent. Joining snapshots
      # to editions on `book_id` meant a fresh price for ONE edition made EVERY
      # edition of that work look freshly scraped — so on a work with six editions,
      # five could never be priced at all.
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
end
