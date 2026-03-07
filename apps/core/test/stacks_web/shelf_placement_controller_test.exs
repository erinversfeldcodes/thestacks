defmodule StacksWeb.ShelfPlacementControllerTest do
  @moduledoc """
  Tests for:
  - POST /api/shelves/:shelf_name/placements
  - PUT  /api/placements/:id/move
  - DELETE /api/placements/:id
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # ---------------------------------------------------------------------------
  # POST /api/shelves/:shelf_name/placements
  # ---------------------------------------------------------------------------

  describe "POST /api/shelves/:shelf_name/placements — create" do
    test "returns 201 with placement on valid shelf and book_id", %{conn: conn} do
      user = insert(:user)
      book = insert(:book)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/shelves/library/placements", %{book_id: book.id})

      assert %{"placement" => placement} = json_response(conn, 201)
      assert placement["book_id"] == book.id
    end

    test "returns 422 for invalid shelf name", %{conn: conn} do
      user = insert(:user)
      book = insert(:book)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/shelves/bad_shelf/placements", %{book_id: book.id})

      assert %{"error" => "invalid shelf name"} = json_response(conn, 422)
    end

    test "returns 422 when book_id is missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/shelves/library/placements", %{})

      assert %{"error" => "book_id is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      book = insert(:book)
      conn = post(conn, "/api/shelves/library/placements", %{book_id: book.id})
      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/placements/:id/move
  # ---------------------------------------------------------------------------

  describe "PUT /api/placements/:id/move — move" do
    setup do
      user = insert(:user)
      shelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: shelf, book: book)
      %{user: user, shelf: shelf, book: book, placement: placement}
    end

    test "returns 200 when user moves own placement", %{conn: conn, user: user, placement: placement} do
      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/move", %{shelf: "wishlist"})

      assert %{"placement" => moved} = json_response(conn, 200)
      assert moved["id"] == placement.id
    end

    test "returns 403 when user moves another user's placement", %{
      conn: conn,
      placement: placement
    } do
      other_user = insert(:user)

      conn =
        conn
        |> auth_conn(other_user)
        |> put("/api/placements/#{placement.id}/move", %{shelf: "wishlist"})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 422 when shelf parameter is missing", %{conn: conn, user: user, placement: placement} do
      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/move", %{})

      assert %{"error" => "shelf parameter is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn, placement: placement} do
      conn = put(conn, "/api/placements/#{placement.id}/move", %{shelf: "wishlist"})
      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/placements/:id
  # ---------------------------------------------------------------------------

  describe "DELETE /api/placements/:id — delete" do
    setup do
      user = insert(:user)
      shelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: shelf, book: book)
      %{user: user, shelf: shelf, book: book, placement: placement}
    end

    test "returns 204 when user deletes own placement", %{
      conn: conn,
      user: user,
      placement: placement
    } do
      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/placements/#{placement.id}")

      assert response(conn, 204)
    end

    test "returns 403 when user deletes another user's placement", %{
      conn: conn,
      placement: placement
    } do
      other_user = insert(:user)

      conn =
        conn
        |> auth_conn(other_user)
        |> delete("/api/placements/#{placement.id}")

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 404 when placement does not exist", %{conn: conn, user: user} do
      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/placements/#{Ecto.UUID.generate()}")

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 401 when not authenticated", %{conn: conn, placement: placement} do
      conn = delete(conn, "/api/placements/#{placement.id}")
      assert json_response(conn, 401)
    end
  end
end
