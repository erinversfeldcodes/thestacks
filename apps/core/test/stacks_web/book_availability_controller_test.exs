defmodule StacksWeb.BookAvailabilityControllerTest do
  @moduledoc "Tests for GET /api/books/:id/availability — public book availability endpoint."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  describe "GET /api/books/:id/availability" do
    test "returns availability for a book that has partner stock", %{conn: conn} do
      book = insert(:book, title: "Middlemarch")
      edition = insert(:book_edition, book: book, isbn: "9780141439549")

      partner =
        insert(:partner,
          name: "The Corner Bookshop",
          status: "approved",
          approved_at: DateTime.utc_now()
        )

      insert(:partner_inventory_item,
        partner: partner,
        book_edition: edition,
        price_cents: 15_000,
        condition: "good",
        quantity: 3
      )

      conn = get(conn, "/api/books/#{book.id}/availability")
      response = json_response(conn, 200)

      assert %{"availability" => [item]} = response
      assert item["partner_name"] == "The Corner Bookshop"
      assert item["price_cents"] == 15_000
      assert item["condition"] == "good"
      assert item["quantity"] == 3
      assert item["isbn"] == "9780141439549"
    end

    test "returns empty array for a book with no stock", %{conn: conn} do
      book = insert(:book, title: "The Mill on the Floss")

      conn = get(conn, "/api/books/#{book.id}/availability")
      response = json_response(conn, 200)

      assert %{"availability" => []} = response
    end

    test "returns 200 (not 404) when book has no availability", %{conn: conn} do
      book = insert(:book, title: "Adam Bede")

      conn = get(conn, "/api/books/#{book.id}/availability")
      assert json_response(conn, 200)
    end

    test "excludes zero-quantity inventory", %{conn: conn} do
      book = insert(:book, title: "Silas Marner")
      edition = insert(:book_edition, book: book, isbn: "9780141439747")

      partner =
        insert(:partner, name: "Empty Shop", status: "approved", approved_at: DateTime.utc_now())

      insert(:partner_inventory_item,
        partner: partner,
        book_edition: edition,
        price_cents: 10_000,
        condition: "good",
        quantity: 0
      )

      conn = get(conn, "/api/books/#{book.id}/availability")
      response = json_response(conn, 200)

      assert %{"availability" => []} = response
    end
  end
end
