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
      book = insert(:book)
      edition = insert(:book_edition, book: book, isbn: "9780749397050")

      conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      assert_enqueued(
        worker: TriggerPriceScrapeJob,
        args: %{isbn: edition.isbn, book_edition_id: edition.id}
      )
    end

    test "does not enqueue for an edition priced inside the TTL", %{conn: conn} do
      # This is what makes reads cheap: a fresh price costs no outbound request.
      book = insert(:book)
      edition = insert(:book_edition, book: book, isbn: "9780749397050")

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
      book = insert(:book)
      edition = insert(:book_edition, book: book, isbn: "9780749397050")

      insert(:price_snapshot,
        book_edition: edition,
        book: book,
        store: insert(:bookstore),
        scraped_at: DateTime.add(DateTime.utc_now(), -30, :day)
      )

      conn |> get("/api/books/#{book.id}/prices") |> json_response(200)

      assert_enqueued(worker: TriggerPriceScrapeJob, args: %{book_edition_id: edition.id})
    end

    test "repeated views do not pile up duplicate scrapes", %{conn: conn} do
      # A popular book is viewed constantly. Without Oban's uniqueness this would
      # enqueue one scrape per page view.
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780749397050")

      Enum.each(1..5, fn _ ->
        conn |> get("/api/books/#{book.id}/prices") |> json_response(200)
      end)

      assert length(all_enqueued(worker: TriggerPriceScrapeJob)) == 1
    end
  end
end
