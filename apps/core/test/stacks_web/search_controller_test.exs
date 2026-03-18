defmodule StacksWeb.SearchControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)
    authed_conn = put_req_header(conn, "authorization", "Bearer #{token}")
    %{conn: authed_conn}
  end

  defp insert_book_with_edition(attrs) do
    book = insert(:book, Keyword.take(attrs, [:title, :author]))

    insert(
      :book_edition,
      Keyword.merge([book: book, is_primary: true], Keyword.take(attrs, [:isbn]))
    )

    book
  end

  describe "GET /api/search" do
    test "returns matching books for query", %{conn: conn} do
      insert_book_with_edition(title: "Elixir in Action", isbn: "9781617295027")
      insert_book_with_edition(title: "Programming Phoenix", isbn: "9781680502268")

      conn = get(conn, "/api/search", q: "Elixir")
      response = json_response(conn, 200)

      assert response["query"] == "Elixir"
      titles = Enum.map(response["results"], & &1["title"])
      assert "Elixir in Action" in titles
      refute "Programming Phoenix" in titles
    end

    test "returns empty results for non-matching query", %{conn: conn} do
      conn = get(conn, "/api/search", q: "ZZZNoMatchZZZ")
      response = json_response(conn, 200)

      assert response["count"] == 0
      assert response["results"] == []
    end

    test "returns 422 when q param missing", %{conn: conn} do
      conn = get(conn, "/api/search")
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "respects a valid limit parameter", %{conn: conn} do
      for i <- 1..5 do
        insert_book_with_edition(title: "Rustica#{i}", isbn: "978000000000#{i}")
      end

      conn = get(conn, "/api/search", q: "Rustica", limit: "2")
      response = json_response(conn, 200)

      assert length(response["results"]) <= 2
    end

    test "ignores invalid limit and defaults to 20", %{conn: conn} do
      conn = get(conn, "/api/search", q: "anything", limit: "not_a_number")
      assert json_response(conn, 200)
    end

    test "returns author info when book has an associated author", %{conn: conn} do
      author = insert(:author, name: "Ursula K. Le Guin")
      insert_book_with_edition(title: "Lefthandedness", isbn: "9780441478125", author: author)

      conn = get(conn, "/api/search", q: "Lefthandedness")
      response = json_response(conn, 200)

      [result | _] = response["results"]
      assert result["author"]["name"] == "Ursula K. Le Guin"
    end

    test "returns 401 without authentication" do
      conn = build_conn() |> get("/api/search", q: "test")
      assert json_response(conn, 401)
    end
  end
end
