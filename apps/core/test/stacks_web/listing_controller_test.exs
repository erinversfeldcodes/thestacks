defmodule StacksWeb.ListingControllerTest do
  @moduledoc "Tests for ListingController CRUD and state transitions."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Marketplace

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp create_listing_for(seller) do
    book = insert(:book)
    bookshelf = insert(:bookshelf, user: seller, name: "looking_for_home")
    insert(:placement, bookshelf: bookshelf, book: book)

    {:ok, listing} =
      Marketplace.create_listing(seller.id, %{
        book_id: book.id,
        pricing_mode: "fixed",
        price_cents: 15_000,
        condition: "good",
        description: "Good condition."
      })

    listing
  end

  describe "GET /api/listings — index" do
    test "returns active listings", %{conn: conn} do
      insert(:listing, status: "active", listed_at: DateTime.utc_now())
      insert(:listing, status: "draft")

      conn = get(conn, "/api/listings")
      assert %{"listings" => listings} = json_response(conn, 200)
      assert length(listings) == 1
    end

    test "returns empty list when no active listings", %{conn: conn} do
      conn = get(conn, "/api/listings")
      assert %{"listings" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/listings/:id — show" do
    test "returns a listing by id", %{conn: conn} do
      listing = insert(:listing)
      conn = get(conn, "/api/listings/#{listing.id}")
      assert %{"listing" => returned} = json_response(conn, 200)
      assert returned["id"] == listing.id
    end

    test "returns 404 for nonexistent listing", %{conn: conn} do
      conn = get(conn, "/api/listings/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/listings/mine" do
    test "returns the current user's listings", %{conn: conn} do
      seller = insert(:user)
      insert(:listing, seller: seller, status: "draft")
      insert(:listing)

      conn =
        conn
        |> auth_conn(seller)
        |> get("/api/listings/mine")

      assert %{"listings" => listings} = json_response(conn, 200)
      assert length(listings) == 1
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      conn = get(conn, "/api/listings/mine")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/listings — create" do
    test "creates a draft listing", %{conn: conn} do
      seller = insert(:user)
      book = insert(:book)
      bookshelf = insert(:bookshelf, user: seller, name: "library")
      insert(:placement, bookshelf: bookshelf, book: book)

      conn =
        conn
        |> auth_conn(seller)
        |> post("/api/listings", %{
          book_id: book.id,
          pricing_mode: "fixed",
          price_cents: 10_000,
          condition: "good"
        })

      assert %{"listing" => listing} = json_response(conn, 201)
      assert listing["status"] == "draft"
      assert listing["price_cents"] == 10_000
    end

    test "returns 422 when seller has no placement", %{conn: conn} do
      seller = insert(:user)
      book = insert(:book)

      conn =
        conn
        |> auth_conn(seller)
        |> post("/api/listings", %{
          book_id: book.id,
          pricing_mode: "fixed",
          price_cents: 10_000,
          condition: "good"
        })

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 422 for invalid params", %{conn: conn} do
      seller = insert(:user)
      book = insert(:book)
      bookshelf = insert(:bookshelf, user: seller, name: "library")
      insert(:placement, bookshelf: bookshelf, book: book)

      conn =
        conn
        |> auth_conn(seller)
        |> post("/api/listings", %{book_id: book.id})

      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "PUT /api/listings/:id/activate" do
    test "activates a draft listing", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{listing.id}/activate")

      assert %{"listing" => activated} = json_response(conn, 200)
      assert activated["status"] == "active"
      assert activated["listed_at"] != nil
    end

    test "returns 403 for non-owner", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)
      other_user = insert(:user)

      conn =
        conn
        |> auth_conn(other_user)
        |> put("/api/listings/#{listing.id}/activate")

      assert json_response(conn, 403)
    end

    test "returns 422 for invalid transition", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)

      conn
      |> auth_conn(seller)
      |> put("/api/listings/#{listing.id}/activate")

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{listing.id}/activate")

      assert %{"error" => "invalid state transition"} = json_response(conn, 422)
    end

    test "returns 404 for nonexistent listing", %{conn: conn} do
      seller = insert(:user)

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{Ecto.UUID.generate()}/activate")

      assert json_response(conn, 404)
    end
  end

  describe "PUT /api/listings/:id/sold" do
    test "marks an active listing as sold", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)

      conn
      |> auth_conn(seller)
      |> put("/api/listings/#{listing.id}/activate")

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{listing.id}/sold")

      assert %{"listing" => sold} = json_response(conn, 200)
      assert sold["status"] == "sold"
      assert sold["sold_at"] != nil
    end

    test "returns 403 for non-owner", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)
      other_user = insert(:user)

      conn
      |> auth_conn(seller)
      |> put("/api/listings/#{listing.id}/activate")

      conn =
        conn
        |> auth_conn(other_user)
        |> put("/api/listings/#{listing.id}/sold")

      assert json_response(conn, 403)
    end

    test "returns 422 for draft listing (invalid transition)", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{listing.id}/sold")

      assert %{"error" => "invalid state transition"} = json_response(conn, 422)
    end

    test "returns 404 for nonexistent listing", %{conn: conn} do
      seller = insert(:user)

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{Ecto.UUID.generate()}/sold")

      assert json_response(conn, 404)
    end
  end

  describe "PUT /api/listings/:id/deactivate" do
    test "deactivates an active listing", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)

      conn
      |> auth_conn(seller)
      |> put("/api/listings/#{listing.id}/activate")

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{listing.id}/deactivate")

      assert %{"listing" => deactivated} = json_response(conn, 200)
      assert deactivated["status"] == "removed"
    end

    test "returns 422 for draft listing", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)

      conn =
        conn
        |> auth_conn(seller)
        |> put("/api/listings/#{listing.id}/deactivate")

      assert %{"error" => "invalid state transition"} = json_response(conn, 422)
    end

    test "returns 403 for non-owner", %{conn: conn} do
      seller = insert(:user)
      listing = create_listing_for(seller)
      other_user = insert(:user)

      conn
      |> auth_conn(seller)
      |> put("/api/listings/#{listing.id}/activate")

      conn =
        conn
        |> auth_conn(other_user)
        |> put("/api/listings/#{listing.id}/deactivate")

      assert json_response(conn, 403)
    end
  end
end
