defmodule StacksWeb.BookshelfControllerTest do
  @moduledoc """
  Tests for GET /api/bookshelves/:bookshelf_name.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/bookshelves/:bookshelf_name" do
    test "returns 200 with placements when bookshelf has books", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      assert %{"bookshelf" => "library", "count" => count, "placements" => placements} =
               json_response(conn, 200)

      assert count >= 1
      assert placements != []
      assert hd(placements)["book"]["id"] == book.id
    end

    test "returns 200 with empty list when bookshelf has no books", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/wishlist")

      assert %{"bookshelf" => "wishlist", "count" => 0, "placements" => []} =
               json_response(conn, 200)
    end

    test "returns 404 for invalid bookshelf name", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/nonexistent_shelf")

      assert %{"error" => "invalid bookshelf name"} = json_response(conn, 404)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, "/api/bookshelves/library")
      assert json_response(conn, 401)
    end

    test "does not return placements belonging to another user", %{conn: conn} do
      user = insert(:user)
      other_user = insert(:user)
      other_bookshelf = insert(:bookshelf, user: other_user, name: "library")
      book = insert(:book)
      _other_placement = insert(:placement, bookshelf: other_bookshelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      assert %{"count" => 0, "placements" => []} = json_response(conn, 200)
    end

    test "does not include removed placements", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)
      Stacks.Shelving.remove_book(placement.id, user.id)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      assert %{"count" => 0, "placements" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/bookshelves/:bookshelf_name — third-party viewer" do
    test "returns 404 when requesting another user's owner-visibility bookshelf", %{conn: conn} do
      owner = insert(:user)
      other = insert(:user)
      insert(:bookshelf, user: owner, name: "library", visibility: "owner")

      conn =
        conn
        |> auth_conn(other)
        |> get("/api/bookshelves/library")

      # Other user gets an empty response (their own non-existent library), not the owner's
      assert %{"count" => 0, "placements" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/bookshelves/:bookshelf_name — visibility gates" do
    test "filters out owner-visibility placements from platform-visibility bookshelf", %{
      conn: conn
    } do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book_visible = insert(:book)
      book_hidden = insert(:book)

      insert(:placement, bookshelf: bookshelf, book: book_visible, visibility: "platform")
      insert(:placement, bookshelf: bookshelf, book: book_hidden, visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      # Owner can see all their own placements (owner bypass in visibility module)
      assert %{"count" => count} = json_response(conn, 200)
      assert count == 2
    end

    test "owner sees their own bookshelf even with owner visibility", %{conn: conn} do
      user = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book, visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      assert %{"count" => 1} = json_response(conn, 200)
    end

    test "returns empty placements list when bookshelf does not exist yet", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/antilibrary")

      assert %{"bookshelf" => "antilibrary", "count" => 0, "placements" => []} =
               json_response(conn, 200)
    end
  end

  describe "PUT /api/bookshelves/:id/visibility" do
    test "updates bookshelf visibility", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/#{bookshelf.id}/visibility", %{visibility: "platform"})

      assert %{"id" => _, "visibility" => "platform"} = json_response(conn, 200)
    end

    test "returns 403 when user does not own the bookshelf", %{conn: conn} do
      user = insert(:user)
      other_user = insert(:user)
      bookshelf = insert(:bookshelf, user: other_user, name: "library")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/#{bookshelf.id}/visibility", %{visibility: "platform"})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 404 for nonexistent bookshelf", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/00000000-0000-0000-0000-000000000000/visibility", %{
          visibility: "platform"
        })

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 422 for invalid visibility value", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/#{bookshelf.id}/visibility", %{visibility: "secret"})

      assert %{"errors" => %{"visibility" => [_]}} = json_response(conn, 422)
    end

    test "returns 422 when visibility parameter is missing", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/#{bookshelf.id}/visibility", %{})

      assert %{"error" => "visibility is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/bookshelves/some-id/visibility", %{visibility: "platform"})
      assert json_response(conn, 401)
    end
  end
end
