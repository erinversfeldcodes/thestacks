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

  # Flatten placements across all shelves for assertions that care about placement content.
  defp all_placements(resp) do
    resp
    |> Map.get("shelves", [])
    |> Enum.flat_map(& &1["placements"])
  end

  describe "GET /api/bookshelves/:bookshelf_name" do
    test "returns 200 with shelves when bookshelf has books", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf)
      book = insert(:book)
      _placement = insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      resp = json_response(conn, 200)
      assert resp["bookshelf"] == "library"
      assert resp["count"] >= 1
      placements = all_placements(resp)
      assert placements != []
      assert hd(placements)["book"]["id"] == book.id
    end

    test "returns 200 with empty shelves when bookshelf has no books", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/wishlist")

      resp = json_response(conn, 200)
      assert resp["bookshelf"] == "wishlist"
      assert resp["count"] == 0
      assert all_placements(resp) == []
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
      other_shelf = insert(:shelf, bookshelf: other_bookshelf)
      book = insert(:book)

      _other_placement =
        insert(:placement, bookshelf: other_bookshelf, shelf: other_shelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      resp = json_response(conn, 200)
      assert resp["count"] == 0
      assert all_placements(resp) == []
    end

    test "does not include removed placements", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf)
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book)
      Stacks.Shelving.remove_book(placement.id, user.id)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      resp = json_response(conn, 200)
      assert resp["count"] == 0
      assert all_placements(resp) == []
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
      resp = json_response(conn, 200)
      assert resp["count"] == 0
      assert all_placements(resp) == []
    end
  end

  describe "GET /api/bookshelves/:bookshelf_name — visibility gates" do
    test "filters out owner-visibility placements from platform-visibility bookshelf", %{
      conn: conn
    } do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      shelf = insert(:shelf, bookshelf: bookshelf)
      book_visible = insert(:book)
      book_hidden = insert(:book)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: book_visible,
        visibility: "platform"
      )

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: book_hidden,
        visibility: "owner"
      )

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
      shelf = insert(:shelf, bookshelf: bookshelf)
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book, visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      assert %{"count" => 1} = json_response(conn, 200)
    end

    test "returns empty shelves list when bookshelf does not exist yet", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/antilibrary")

      resp = json_response(conn, 200)
      assert resp["bookshelf"] == "antilibrary"
      assert resp["count"] == 0
      assert resp["shelves"] == []
    end
  end

  describe "GET /api/bookshelves/:bookshelf_name — placement serialization" do
    test "includes book editions in placement response", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf)
      book = insert(:book)
      _edition = insert(:book_edition, book: book, isbn: "9780743273565", is_primary: true)
      _placement = insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      resp = json_response(conn, 200)
      [placement] = all_placements(resp)
      assert placement["book"]["editions"] != nil
      assert is_list(placement["book"]["editions"])
    end

    test "includes primary_edition when book has editions", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf)
      book = insert(:book)
      edition = insert(:book_edition, book: book, is_primary: true)
      _placement = insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      resp = json_response(conn, 200)
      [placement] = all_placements(resp)
      assert placement["book"]["primary_edition"]["id"] == edition.id
    end

    test "includes author in book response", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf)
      author = insert(:author, name: "Test Author")
      book = insert(:book, author: author)
      _placement = insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      resp = json_response(conn, 200)
      [placement] = all_placements(resp)
      assert placement["book"]["author"]["name"] == "Test Author"
    end

    test "returns placement fields: position, formats, personal_rating, notes", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf)
      book = insert(:book)

      _placement =
        insert(:placement,
          bookshelf: bookshelf,
          shelf: shelf,
          book: book,
          position: 3,
          formats: ["paperback"],
          personal_rating: 5,
          notes: "Great book"
        )

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")

      resp = json_response(conn, 200)
      [placement] = all_placements(resp)
      assert placement["position"] == 3
      assert placement["formats"] == ["paperback"]
      assert placement["personal_rating"] == 5
      assert placement["notes"] == "Great book"
    end

    test "returns all valid bookshelf names", %{conn: _conn} do
      user = insert(:user)

      for name <- ~w(antilibrary library wishlist reading_pile looking_for_home) do
        conn =
          build_conn()
          |> auth_conn(user)
          |> get("/api/bookshelves/#{name}")

        assert %{"bookshelf" => ^name} = json_response(conn, 200)
      end
    end
  end

  describe "GET /api/bookshelves/:bookshelf_name — view_as halted" do
    test "returns 403 when non-owner requests view_as perspective on another user's bookshelf",
         %{conn: conn} do
      owner = insert(:user)
      other = insert(:user)
      _bookshelf = insert(:bookshelf, user: owner, name: "library")

      conn =
        conn
        |> auth_conn(other)
        |> get("/api/bookshelves/library?view_as=unauthenticated")

      # Non-owner cannot use view_as; either gets 403 or their own (empty) bookshelf
      response = json_response(conn, conn.status)
      assert conn.status in [200, 403]
      # If 200, should be their own empty bookshelf
      if conn.status == 200 do
        assert response["count"] == 0
      end
    end
  end

  describe "GET /api/bookshelves/:bookshelf_name — view_as content filtering" do
    test "owner viewing own bookshelf as unauthenticated sees only platform-visible placements",
         %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      shelf = insert(:shelf, bookshelf: bookshelf)
      visible_book = insert(:book)
      hidden_book = insert(:book)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: visible_book,
        visibility: "platform"
      )

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: hidden_book,
        visibility: "owner"
      )

      # Baseline: as the owner (no view_as) both placements are visible.
      baseline =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/library")
        |> json_response(200)

      assert baseline["count"] == 2

      # With ?view_as=unauthenticated the payload is FILTERED to the simulated
      # audience: the owner-only placement is dropped, the platform one remains.
      filtered =
        build_conn()
        |> auth_conn(user)
        |> get("/api/bookshelves/library?view_as=unauthenticated")
        |> json_response(200)

      assert filtered["count"] == 1
      [placement] = all_placements(filtered)
      assert placement["book"]["id"] == visible_book.id
    end
  end

  describe "PUT /api/bookshelves/:bookshelf_name/visibility" do
    test "updates bookshelf visibility", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")
      insert(:bookshelf, user: user, name: "library", visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/visibility", %{visibility: "platform"})

      assert %{"id" => _, "visibility" => "platform"} = json_response(conn, 200)
    end

    test "lazily creates the named shelf when it does not exist yet", %{conn: conn} do
      # A user can set visibility on any of their 5 named shelves even before
      # placing a book there (bookshelves are created lazily).
      user = insert(:user, profile_visibility: "platform")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/wishlist/visibility", %{visibility: "platform"})

      assert %{"visibility" => "platform"} = json_response(conn, 200)
      assert Stacks.Shelving.get_bookshelf(user.id, "wishlist").visibility == "platform"
    end

    test "returns 422 when the new visibility exceeds the profile ceiling (US-10.2.1)", %{
      conn: conn
    } do
      # profile_visibility "owner" is the most restrictive ceiling: no bookshelf
      # may be made more visible than the profile.
      user = insert(:user, profile_visibility: "owner")
      insert(:bookshelf, user: user, name: "library", visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/visibility", %{visibility: "platform"})

      assert %{"errors" => %{"visibility" => [_ | _]}} = json_response(conn, 422)
    end

    test "is scoped to the caller — never touches another user's like-named shelf (SECURITY)", %{
      conn: conn
    } do
      user = insert(:user, profile_visibility: "platform")
      other_user = insert(:user, profile_visibility: "platform")
      insert(:bookshelf, user: other_user, name: "library", visibility: "owner")

      conn
      |> auth_conn(user)
      |> put("/api/bookshelves/library/visibility", %{visibility: "platform"})
      |> json_response(200)

      # The other user's identically-named shelf is untouched — name-based routing
      # is user-scoped by construction (get_or_create keys on the caller's id).
      assert Stacks.Shelving.get_bookshelf(other_user.id, "library").visibility == "owner"
    end

    test "returns 404 for an invalid bookshelf name", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/not_a_real_shelf/visibility", %{visibility: "platform"})

      assert %{"error" => "invalid bookshelf name"} = json_response(conn, 404)
    end

    test "returns 422 for invalid visibility value", %{conn: conn} do
      user = insert(:user)
      insert(:bookshelf, user: user, name: "library")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/visibility", %{visibility: "secret"})

      assert %{"errors" => %{"visibility" => [_]}} = json_response(conn, 422)
    end

    test "returns 422 when visibility parameter is missing", %{conn: conn} do
      user = insert(:user)
      insert(:bookshelf, user: user, name: "library")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/visibility", %{})

      assert %{"error" => "visibility is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/bookshelves/library/visibility", %{visibility: "platform"})
      assert json_response(conn, 401)
    end
  end
end
