defmodule StacksWeb.ShelfControllerTest do
  @moduledoc """
  Tests for GET /api/shelves/:shelf_name.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/shelves/:shelf_name" do
    test "returns 200 with placements when shelf has books", %{conn: conn} do
      user = insert(:user)
      shelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      _placement = insert(:placement, bookshelf: shelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/shelves/library")

      assert %{"shelf" => "library", "count" => count, "placements" => placements} =
               json_response(conn, 200)

      assert count >= 1
      assert length(placements) >= 1
      assert hd(placements)["book"]["id"] == book.id
    end

    test "returns 200 with empty list when shelf has no books", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/shelves/wishlist")

      assert %{"shelf" => "wishlist", "count" => 0, "placements" => []} =
               json_response(conn, 200)
    end

    test "returns 404 for invalid shelf name", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/shelves/nonexistent_shelf")

      assert %{"error" => "invalid shelf name"} = json_response(conn, 404)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, "/api/shelves/library")
      assert json_response(conn, 401)
    end

    test "does not return placements belonging to another user", %{conn: conn} do
      user = insert(:user)
      other_user = insert(:user)
      other_shelf = insert(:bookshelf, user: other_user, name: "library")
      book = insert(:book)
      _other_placement = insert(:placement, bookshelf: other_shelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/shelves/library")

      assert %{"count" => 0, "placements" => []} = json_response(conn, 200)
    end

    test "does not include removed placements", %{conn: conn} do
      user = insert(:user)
      shelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: shelf, book: book)
      Stacks.Shelving.remove_book(placement.id, user.id)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/shelves/library")

      assert %{"count" => 0, "placements" => []} = json_response(conn, 200)
    end
  end
end
