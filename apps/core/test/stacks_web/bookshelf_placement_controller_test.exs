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
  # GET /api/placements/mine
  # ---------------------------------------------------------------------------

  describe "GET /api/placements/mine — mine" do
    test "returns empty list when user has no placements", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/placements/mine")

      assert %{"placements" => []} = json_response(conn, 200)
    end

    test "returns summary of user's active placements", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book1 = insert(:book, title: "The Left Hand of Darkness")
      book2 = insert(:book, title: "A Wizard of Earthsea")
      insert(:placement, bookshelf: bookshelf, book: book1)
      insert(:placement, bookshelf: bookshelf, book: book2)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/placements/mine")

      assert %{"placements" => placements} = json_response(conn, 200)
      assert length(placements) == 2
      assert Enum.all?(placements, &(&1["bookshelf_name"] == "library"))

      book_ids = Enum.map(placements, & &1["book_id"])
      assert book1.id in book_ids
      assert book2.id in book_ids

      # Each summary carries the book title for the marketplace listing dropdown.
      assert Enum.all?(placements, &(is_binary(&1["title"]) and &1["title"] != ""))

      titles = Enum.map(placements, & &1["title"])
      assert "The Left Hand of Darkness" in titles
      assert "A Wizard of Earthsea" in titles
    end

    test "excludes removed placements", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book, removed_at: DateTime.utc_now())

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/placements/mine")

      assert %{"placements" => []} = json_response(conn, 200)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, "/api/placements/mine")
      assert json_response(conn, 401)
    end
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

    test "returns 422 with reading_pile_full code when the pile is at the 50 cap", %{conn: conn} do
      user = insert(:user)
      fill_reading_pile(user, 50)
      book = insert(:book)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/bookshelves/reading_pile/placements", %{book_id: book.id})

      assert %{"error" => "reading_pile_full"} = json_response(conn, 422)
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

    test "returns 422 with reading_pile_full code when moving into a full pile", %{
      conn: conn,
      user: user,
      placement: placement
    } do
      fill_reading_pile(user, 50)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/placements/#{placement.id}/move", %{bookshelf: "reading_pile"})

      assert %{"error" => "reading_pile_full"} = json_response(conn, 422)
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

  describe "PUT /api/placements/:id/visibility" do
    setup %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      placement = insert(:placement, bookshelf: bookshelf, visibility: "owner")
      {:ok, conn: auth_conn(conn, user), user: user, bookshelf: bookshelf, placement: placement}
    end

    test "updates placement visibility within ceiling", %{conn: conn, placement: placement} do
      conn = put(conn, "/api/placements/#{placement.id}/visibility", %{visibility: "platform"})
      assert %{"id" => _, "visibility" => "platform"} = json_response(conn, 200)
    end

    test "returns 422 when visibility exceeds bookshelf ceiling", %{conn: conn, user: user} do
      owner_bookshelf = insert(:bookshelf, user: user, name: "wishlist", visibility: "owner")
      placement = insert(:placement, bookshelf: owner_bookshelf, visibility: "owner")

      conn = put(conn, "/api/placements/#{placement.id}/visibility", %{visibility: "platform"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 403 when user does not own the placement", %{conn: _conn, placement: placement} do
      other_user = insert(:user)

      conn =
        build_conn()
        |> auth_conn(other_user)
        |> put("/api/placements/#{placement.id}/visibility", %{visibility: "owner"})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 404 for nonexistent placement", %{conn: conn} do
      conn =
        put(conn, "/api/placements/00000000-0000-0000-0000-000000000000/visibility", %{
          visibility: "owner"
        })

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 422 when visibility parameter is missing", %{conn: conn, placement: placement} do
      conn = put(conn, "/api/placements/#{placement.id}/visibility", %{})
      assert %{"error" => "visibility is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{placement: placement} do
      conn =
        build_conn()
        |> put("/api/placements/#{placement.id}/visibility", %{visibility: "owner"})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/placements/:id/progress  (Issue #148)
  # ---------------------------------------------------------------------------

  describe "PUT /api/placements/:id/progress — update_progress" do
    setup %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      %{
        conn: auth_conn(conn, user),
        user: user,
        placement: placement
      }
    end

    test "returns 200 with updated placement on valid reading_status", %{
      conn: conn,
      placement: placement
    } do
      conn =
        put(conn, "/api/placements/#{placement.id}/progress", %{reading_status: "reading"})

      assert %{"placement" => updated} = json_response(conn, 200)
      assert updated["reading_status"] == "reading"
    end

    test "returns 200 and updates current_page along with status", %{
      conn: conn,
      placement: placement
    } do
      conn =
        put(conn, "/api/placements/#{placement.id}/progress", %{
          reading_status: "reading",
          current_page: 75
        })

      assert %{"placement" => updated} = json_response(conn, 200)
      assert updated["current_page"] == 75
    end

    test "returns 403 when user does not own the placement", %{placement: placement} do
      other_user = insert(:user)

      conn =
        build_conn()
        |> auth_conn(other_user)
        |> put("/api/placements/#{placement.id}/progress", %{reading_status: "reading"})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 422 for invalid reading_status", %{conn: conn, placement: placement} do
      conn =
        put(conn, "/api/placements/#{placement.id}/progress", %{reading_status: "nope"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 for negative current_page", %{conn: conn, placement: placement} do
      conn =
        put(conn, "/api/placements/#{placement.id}/progress", %{
          reading_status: "reading",
          current_page: -5
        })

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 when reading_status is missing", %{conn: conn, placement: placement} do
      conn = put(conn, "/api/placements/#{placement.id}/progress", %{})

      assert json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{placement: placement} do
      conn =
        build_conn()
        |> put("/api/placements/#{placement.id}/progress", %{reading_status: "reading"})

      assert json_response(conn, 401)
    end

    test "returns 422 with a current_page field error when the page exceeds the book's page count",
         %{conn: conn, user: user} do
      book = insert(:book)
      insert(:book_edition, book: book, page_count: 112, is_primary: true)
      bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      conn =
        put(conn, "/api/placements/#{placement.id}/progress", %{
          reading_status: "reading",
          current_page: 999_999
        })

      assert %{"errors" => %{"current_page" => [_ | _]}} = json_response(conn, 422)
    end
  end

  # Fills the user's reading_pile bookshelf with `count` active placements,
  # inserted directly so the 50-cap (#276) boundary can be staged.
  defp fill_reading_pile(user, count) when count >= 1 do
    bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
    shelf = insert(:shelf, bookshelf: bookshelf)

    for _ <- 1..count do
      insert(:placement, bookshelf: bookshelf, shelf: shelf, book: insert(:book))
    end

    bookshelf
  end
end
