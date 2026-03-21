defmodule StacksWeb.FeedControllerTest do
  @moduledoc """
  Tests for GET /api/feeds/:user_id/:bookshelf_name.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  describe "GET /api/feeds/:user_id/:bookshelf_name" do
    test "returns 200 with Atom XML for a platform-visible bookshelf", %{conn: conn} do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      author = insert(:author, name: "Donna Tartt")
      book = insert(:book, title: "The Secret History", author: author)
      _edition = insert(:book_edition, book: book, isbn: "9780140167771", is_primary: true)
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      conn = get(conn, "/api/feeds/#{user.id}/library")

      assert conn.status == 200
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert String.contains?(content_type, "application/atom+xml")
      assert {"etag", _etag} = List.keyfind(conn.resp_headers, "etag", 0)
      assert String.contains?(conn.resp_body, "<feed xmlns=")
      assert String.contains?(conn.resp_body, "The Secret History")
    end

    test "returns 304 Not Modified when ETag matches", %{conn: conn} do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "Stable Book")
      fixed_time = ~U[2026-01-01 12:00:00.000000Z]
      _placement = insert(:placement, bookshelf: bookshelf, book: book, placed_at: fixed_time)

      # First request to get the ETag
      conn1 = get(conn, "/api/feeds/#{user.id}/library")
      assert conn1.status == 200
      {"etag", etag} = List.keyfind(conn1.resp_headers, "etag", 0)

      # Second request with If-None-Match
      conn2 =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/api/feeds/#{user.id}/library")

      assert conn2.status == 304
    end

    test "returns 404 for nonexistent bookshelf", %{conn: conn} do
      conn = get(conn, "/api/feeds/#{Ecto.UUID.generate()}/library")

      assert %{"error" => "Bookshelf not found"} = json_response(conn, 404)
    end

    test "returns 403 for non-platform-visible bookshelf", %{conn: conn} do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      conn = get(conn, "/api/feeds/#{user.id}/library")

      assert %{"error" => error} = json_response(conn, 403)
      assert String.contains?(error, "platform-visible")
    end
  end
end
