defmodule StacksWeb.BookshelfPlacementControllerTest do
  @moduledoc """
  Tests for:
  - POST /api/bookshelves/:bookshelf_name/placements
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
  # POST /api/bookshelves/:bookshelf_name/placements
  # ---------------------------------------------------------------------------

  describe "POST /api/bookshelves/:bookshelf_name/placements — create" do
    test "returns 201 with placement on valid bookshelf and book_id", %{conn: conn} do
      user = insert(:user)
      book = insert(:book)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/bookshelves/library/placements", %{book_id: book.id})

      assert %{"placement" => placement} = json_response(conn, 201)
      assert placement["book_id"] == book.id
    end

    test "returns 422 for invalid bookshelf name", %{conn: conn} do
      user = insert(:user)
      book = insert(:book)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/bookshelves/bad_shelf/placements", %{book_id: book.id})

      assert %{"error" => "invalid bookshelf name"} = json_response(conn, 422)
    end

    test "returns 422 when book_id is missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/bookshelves/library/placements", %{})

      assert %{"error" => "book_id is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      book = insert(:book)
      conn = post(conn, "/api/bookshelves/library/placements", %{book_id: book.id})
      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/placements/:id/move
  # ---------------------------------------------------------------------------

  describe "PUT /api/placements/:id/move — move" do
    setup do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)
      %{user: user, bookshelf: bookshelf, book: book, placement: placement}
    end

    test "returns 200 when user moves own placement", %{
      conn: conn,
      user: user,
      placement: placement
    } do
      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/move", %{bookshelf: "wishlist"})

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
        |> put("/api/placements/#{placement.id}/move", %{bookshelf: "wishlist"})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 422 when bookshelf parameter is missing", %{
      conn: conn,
      user: user,
      placement: placement
    } do
      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/move", %{})

      assert %{"error" => "bookshelf parameter is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn, placement: placement} do
      conn = put(conn, "/api/placements/#{placement.id}/move", %{bookshelf: "wishlist"})
      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/placements/:id
  # ---------------------------------------------------------------------------

  describe "DELETE /api/placements/:id — delete" do
    setup do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)
      %{user: user, bookshelf: bookshelf, book: book, placement: placement}
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

  # ---------------------------------------------------------------------------
  # PUT /api/placements/:id/formats
  # ---------------------------------------------------------------------------

  describe "PUT /api/placements/:id/formats — update_formats" do
    setup %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)
      other_user = insert(:user)

      %{
        conn: auth_conn(conn, user),
        user: user,
        placement: placement,
        other_user: other_user
      }
    end

    test "returns 200 with updated formats", %{conn: conn, placement: placement} do
      conn = put(conn, "/api/placements/#{placement.id}/formats", %{formats: ["hardcover"]})
      assert %{"placement" => %{"formats" => ["hardcover"]}} = json_response(conn, 200)
    end

    test "returns 200 with multiple formats", %{conn: conn, placement: placement} do
      conn =
        put(conn, "/api/placements/#{placement.id}/formats", %{
          formats: ["hardcover", "ebook"]
        })

      response = json_response(conn, 200)
      assert "hardcover" in response["placement"]["formats"]
      assert "ebook" in response["placement"]["formats"]
    end

    test "returns 403 when user tries to update another user's placement formats", %{
      conn: conn,
      other_user: other_user
    } do
      other_bookshelf = insert(:bookshelf, user: other_user)
      other_placement = insert(:placement, bookshelf: other_bookshelf, book: insert(:book))

      conn =
        put(conn, "/api/placements/#{other_placement.id}/formats", %{formats: ["hardcover"]})

      assert json_response(conn, 403)
    end

    test "returns 422 when formats parameter is missing", %{conn: conn, placement: placement} do
      conn = put(conn, "/api/placements/#{placement.id}/formats", %{})
      assert json_response(conn, 422)
    end

    test "returns 422 when formats is not an array", %{conn: conn, placement: placement} do
      conn =
        put(conn, "/api/placements/#{placement.id}/formats", %{formats: "not_an_array"})

      assert json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: _conn, placement: placement} do
      conn = build_conn() |> put("/api/placements/#{placement.id}/formats", %{formats: []})
      assert json_response(conn, 401)
    end
  end
end
