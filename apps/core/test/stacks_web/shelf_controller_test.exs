defmodule StacksWeb.ShelfControllerTest do
  @moduledoc """
    Tests for the shelf management endpoints:
    - GET    /api/bookshelves/:name/shelves
    - POST   /api/bookshelves/:name/shelves
    - DELETE /api/shelves/:id
    - PUT    /api/bookshelves/:name/shelves/reorder
    - PUT    /api/placements/:id/shelf  (new action on BookshelfPlacementController)
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp setup_bookshelf_with_shelves(_ctx) do
    user = insert(:user)
    bookshelf = insert(:bookshelf, user: user, name: "library")
    shelf_a = insert(:shelf, bookshelf: bookshelf, position: 0)
    shelf_b = insert(:shelf, bookshelf: bookshelf, position: 1)

    %{user: user, bookshelf: bookshelf, shelf_a: shelf_a, shelf_b: shelf_b}
  end

  describe "GET /api/bookshelves/:name/shelves — index" do
    setup :setup_bookshelf_with_shelves

    test "returns 200 with list of shelves", %{
      conn: conn,
      user: user,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library/shelves")

      assert %{"shelves" => shelves} = json_response(conn, 200)
      assert length(shelves) == 2
      ids = Enum.map(shelves, & &1["id"])
      assert shelf_a.id in ids
      assert shelf_b.id in ids
    end

    test "returns shelves in position order", %{
      conn: conn,
      user: user,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library/shelves")

      %{"shelves" => shelves} = json_response(conn, 200)
      ids = Enum.map(shelves, & &1["id"])
      assert ids == [shelf_a.id, shelf_b.id]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, "/api/bookshelves/library/shelves")
      assert json_response(conn, 401)
    end

    test "does not claim to carry placements, even for a shelf holding books", %{
      conn: conn,
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a
    } do
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library/shelves")

      %{"shelves" => shelves} = json_response(conn, 200)
      loaded = Enum.find(shelves, &(&1["id"] == shelf_a.id))

      assert loaded, "the shelf holding the book was not returned at all"

      refute Map.has_key?(loaded, "placements"),
             "the shelf payload carries a `placements` key again — if it is empty it is a " <>
               "lie, and the SPA will paint an empty bookcase over a full one"
    end
  end

  describe "POST /api/bookshelves/:name/shelves — create" do
    setup :setup_bookshelf_with_shelves

    test "returns 201 with new shelf", %{conn: conn, user: user} do
      conn =
        conn
        |> auth_conn(user)
        |> post("/api/bookshelves/library/shelves")

      assert %{"shelf" => shelf} = json_response(conn, 201)
      assert shelf["position"] != nil
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = post(conn, "/api/bookshelves/library/shelves")
      assert json_response(conn, 401)
    end

    test "returns 403 when user does not own the bookshelf", %{conn: conn, bookshelf: _bookshelf} do
      other_user = insert(:user)

      conn =
        conn
        |> auth_conn(other_user)
        |> post("/api/bookshelves/library/shelves")

      status = conn.status
      assert status in [403, 404]
    end
  end

  describe "DELETE /api/shelves/:id — delete" do
    setup :setup_bookshelf_with_shelves

    test "returns 200 when deleting an empty shelf", %{conn: conn, user: user, shelf_b: shelf_b} do
      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/shelves/#{shelf_b.id}")

      assert response(conn, 200)
    end

    test "returns 422 when shelf has placements", %{
      conn: conn,
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a
    } do
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/shelves/#{shelf_a.id}")

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 404 when shelf does not exist", %{conn: conn, user: user} do
      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/shelves/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns 401 when not authenticated", %{conn: conn, shelf_a: shelf_a} do
      conn = delete(conn, "/api/shelves/#{shelf_a.id}")
      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/bookshelves/:name/shelves/reorder — reorder" do
    setup :setup_bookshelf_with_shelves

    test "returns 200 when reorder succeeds", %{
      conn: conn,
      user: user,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/shelves/reorder", %{
          shelf_ids: [shelf_b.id, shelf_a.id]
        })

      assert json_response(conn, 200)
    end

    test "returns 422 when shelf_ids contains invalid ids", %{
      conn: conn,
      user: user,
      shelf_a: shelf_a
    } do
      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/shelves/reorder", %{
          shelf_ids: [shelf_a.id, Ecto.UUID.generate()]
        })

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn, shelf_a: shelf_a, shelf_b: shelf_b} do
      conn =
        put(conn, "/api/bookshelves/library/shelves/reorder", %{
          shelf_ids: [shelf_b.id, shelf_a.id]
        })

      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/placements/:id/shelf — move placement to shelf" do
    setup :setup_bookshelf_with_shelves

    test "returns 200 when valid", %{
      conn: conn,
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/shelf", %{shelf_id: shelf_b.id})

      assert %{"placement" => updated} = json_response(conn, 200)
      assert updated["shelf_id"] == shelf_b.id
    end

    test "returns 422 when target shelf is on a different bookshelf", %{
      conn: conn,
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a
    } do
      other_bookshelf = insert(:bookshelf, user: user, name: "wishlist")
      other_shelf = insert(:shelf, bookshelf: other_bookshelf, position: 0)

      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/shelf", %{shelf_id: other_shelf.id})

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      conn =
        build_conn()
        |> put("/api/placements/#{placement.id}/shelf", %{shelf_id: shelf_b.id})

      assert json_response(conn, 401)
    end

    test "returns 404 for a nonexistent placement id", %{conn: conn, user: user, shelf_b: shelf_b} do
      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{Ecto.UUID.generate()}/shelf", %{shelf_id: shelf_b.id})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 404 for a nonexistent target shelf id", %{
      conn: conn,
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a
    } do
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/shelf", %{shelf_id: Ecto.UUID.generate()})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end
end
