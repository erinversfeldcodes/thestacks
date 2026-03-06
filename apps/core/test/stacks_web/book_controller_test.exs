defmodule StacksWeb.BookControllerTest do
  @moduledoc """
  Tests for GET /api/books/:id and GET /api/books/isbn/:isbn.

  Both routes are behind the :authenticated pipeline. Tests authenticate via
  Guardian token. The AgeGate plug is also exercised here for age_gated books.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/books/:id" do
    test "returns 200 with book JSON when book exists", %{conn: conn} do
      user = insert(:user)
      book = insert(:book, title: "Middlemarch", visibility_tier: "public")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => returned} = json_response(conn, 200)
      assert returned["id"] == book.id
      assert returned["title"] == "Middlemarch"
      assert returned["isbn"] == book.isbn
      assert returned["visibility_tier"] == "public"
    end

    test "returns 404 when book does not exist", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{Ecto.UUID.generate()}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      book = insert(:book)
      conn = get(conn, "/api/books/#{book.id}")
      assert json_response(conn, 401)
    end

    test "returns 403 for age_gated book when user is not age_verified", %{conn: conn} do
      user = insert(:user, age_verified: false)
      book = insert(:book, visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end

    test "returns 200 for age_gated book when user is age_verified", %{conn: conn} do
      user = insert(:user, age_verified: true)
      book = insert(:book, visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => _} = json_response(conn, 200)
    end
  end

  describe "GET /api/books/isbn/:isbn" do
    test "returns 200 when book with ISBN exists", %{conn: conn} do
      user = insert(:user)
      book = insert(:book, isbn: "9780451524935", visibility_tier: "public")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/isbn/9780451524935")

      assert %{"book" => returned} = json_response(conn, 200)
      assert returned["isbn"] == "9780451524935"
      assert returned["id"] == book.id
    end

    test "returns 404 when ISBN is not found", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/isbn/0000000000000")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, "/api/books/isbn/9780451524935")
      assert json_response(conn, 401)
    end

    test "returns 403 for age_gated book when user is not age_verified", %{conn: conn} do
      user = insert(:user, age_verified: false)
      insert(:book, isbn: "9780000000001", visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/isbn/9780000000001")

      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end
  end
end
