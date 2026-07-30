defmodule StacksWeb.BookPriceControllerTest do
  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.TriggerPriceScrapeJob

  describe "GET /api/books/:id/prices" do
    test "returns a price per (edition, store), keyed by edition", %{conn: conn} do
      # Exclusive Books carries six ISBNs of The Name of the Rose at different
      # prices. Exposing only the work would show one arbitrary price as though it
      # were the price of the book.
      book = insert(:book)
      paperback = insert(:book_edition, book: book, isbn: "9780749397050")
      spanish = insert(:book_edition, book: book, isbn: "9788497592581", is_primary: false)
      store = insert(:bookstore)

      insert(:price_snapshot,
        book_edition: paperback,
        book: book,
        store: store,
        price_cents: 40_000
      )

      insert(:price_snapshot,
        book_edition: spanish,
        book: book,
        store: store,
        price_cents: 41_100
      )

      body = conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      assert length(body["prices"]) == 2
      by_edition = Map.new(body["prices"], &{&1["book_edition_id"], &1["price_cents"]})
      assert by_edition[paperback.id] == 40_000
      assert by_edition[spanish.id] == 41_100
    end

    test "returns an empty list rather than 404 for a book with no prices", %{conn: conn} do
      book = insert(:book)
      assert %{"prices" => []} = conn |> get("/api/books/#{book.id}/prices") |> json_response(200)
    end

    test "does not leak another work's prices", %{conn: conn} do
      book = insert(:book)
      other = insert(:book)
      other_edition = insert(:book_edition, book: other)

      insert(:price_snapshot,
        book_edition: other_edition,
        book: other,
        store: insert(:bookstore)
      )

      assert %{"prices" => []} = conn |> get("/api/books/#{book.id}/prices") |> json_response(200)
    end
  end

  describe "lazy refresh on read" do
    setup do
      # Enabled explicitly: it is off in :test so ordinary reads do not enqueue
      # jobs every other test would have to account for.
      Application.put_env(:core, :lazy_price_refresh, true)
      on_exit(fn -> Application.put_env(:core, :lazy_price_refresh, false) end)
      :ok
    end

    test "enqueues a scrape for an edition that has never been priced", %{conn: conn} do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780749397050")])
      edition = hd(book.editions)

      conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      assert_enqueued(
        worker: TriggerPriceScrapeJob,
        args: %{isbn: edition.isbn, book_edition_id: edition.id}
      )
    end

    test "does not enqueue for an edition priced inside the TTL", %{conn: conn} do
      # This is what makes reads cheap: a fresh price costs no outbound request.
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780749397050")])
      edition = hd(book.editions)

      insert(:price_snapshot,
        book_edition: edition,
        book: book,
        store: insert(:bookstore),
        scraped_at: DateTime.utc_now()
      )

      conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      refute_enqueued(worker: TriggerPriceScrapeJob)
    end

    test "enqueues for an edition whose price has gone stale", %{conn: conn} do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780749397050")])
      edition = hd(book.editions)

      insert(:price_snapshot,
        book_edition: edition,
        book: book,
        store: insert(:bookstore),
        scraped_at: DateTime.add(DateTime.utc_now(), -30, :day)
      )

      conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      assert_enqueued(worker: TriggerPriceScrapeJob, args: %{book_edition_id: edition.id})
    end

    test "caps the fan-out for a much-republished work", %{conn: conn} do
      # Open Library reports 76 distinct ISBN-13s for The Name of the Rose. With
      # eleven seeded stores, an uncapped fan-out turns one page view into ~800
      # outbound requests against mostly one-person bookshops.
      book = insert(:book)

      # The work's own primary edition is edition 1; these are the reprints.
      Enum.each(2..12, fn i ->
        insert(:book_edition,
          book: book,
          isbn: "97800000000#{String.pad_leading(to_string(i), 2, "0")}",
          is_primary: false
        )
      end)

      conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      enqueued = all_enqueued(worker: TriggerPriceScrapeJob)
      assert length(enqueued) == 5, "expected the fan-out to be capped, got #{length(enqueued)}"
    end

    test "spends the first requests on the primary edition", %{conn: conn} do
      # It is the edition the page leads with, so it is the one worth pricing first.
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780000000099")])
      primary = hd(book.editions)

      Enum.each(1..10, fn i ->
        insert(:book_edition,
          book: book,
          isbn: "97800000000#{String.pad_leading(to_string(i), 2, "0")}",
          is_primary: false
        )
      end)

      conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      isbns = all_enqueued(worker: TriggerPriceScrapeJob) |> Enum.map(& &1.args["isbn"])
      assert primary.isbn in isbns
    end

    test "repeated views do not pile up duplicate scrapes", %{conn: conn} do
      # A popular book is viewed constantly. Without Oban's uniqueness this would
      # enqueue one scrape per page view.
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780749397050")])

      Enum.each(1..5, fn _ ->
        conn |> get("/api/books/#{book.id}/prices") |> json_response(200)
      end)

      assert length(all_enqueued(worker: TriggerPriceScrapeJob)) == 1
    end
  end
end
