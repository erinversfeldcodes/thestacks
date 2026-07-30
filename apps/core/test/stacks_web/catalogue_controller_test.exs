defmodule StacksWeb.CatalogueControllerTest do
  @moduledoc """
  Tests for GET /api/catalogue — the public book catalogue endpoint.

  Verifies pagination, search, subject filtering, sort, and most
  importantly that no ownership data is ever exposed.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp insert_book_with_edition(attrs \\ []) do
    book =
      insert(
        :book,
        Keyword.take(attrs, [:title, :visibility_tier, :author, :subjects]) ++
          [editions: [build(:primary_book_edition, Keyword.take(attrs, [:isbn]))]]
      )

    {book, hd(book.editions)}
  end

  describe "GET /api/catalogue" do
    test "returns 200 when not authenticated (public endpoint)", %{conn: conn} do
      conn = get(conn, "/api/catalogue")
      assert %{"books" => _, "total" => _} = json_response(conn, 200)
    end

    test "returns paginated books with no ownership data", %{conn: conn} do
      user = insert(:user)
      author = insert(:author, name: "George Eliot")

      insert_book_with_edition(
        title: "Middlemarch",
        author: author,
        visibility_tier: "public"
      )

      insert_book_with_edition(
        title: "Silas Marner",
        author: author,
        visibility_tier: "public"
      )

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue")

      assert %{"books" => books, "total" => total, "page" => 1, "per_page" => 24} =
               json_response(conn, 200)

      assert total == 2
      assert length(books) == 2

      # Verify no ownership data is present
      for book <- books do
        refute Map.has_key?(book, "user_id")
        refute Map.has_key?(book, "owner")
        refute Map.has_key?(book, "shelf")
        refute Map.has_key?(book, "placement")
        refute Map.has_key?(book, "owner_count")
        assert Map.has_key?(book, "id")
        assert Map.has_key?(book, "title")
        assert Map.has_key?(book, "editions")
        assert Map.has_key?(book, "primary_edition")
      end
    end

    test "sorts by title ascending by default", %{conn: conn} do
      user = insert(:user)
      insert_book_with_edition(title: "Zebra Book")
      insert_book_with_edition(title: "Aardvark Book")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue")

      %{"books" => books} = json_response(conn, 200)
      titles = Enum.map(books, & &1["title"])
      assert titles == ["Aardvark Book", "Zebra Book"]
    end

    test "sorts by recent when requested", %{conn: conn} do
      user = insert(:user)
      insert_book_with_edition(title: "Old Book")
      insert_book_with_edition(title: "New Book")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue", %{"sort" => "recent"})

      %{"books" => books} = json_response(conn, 200)
      assert List.first(books)["title"] == "New Book"
    end

    test "filters by subject", %{conn: conn} do
      user = insert(:user)
      insert_book_with_edition(title: "Fiction Book", subjects: ["fiction", "drama"])
      insert_book_with_edition(title: "Science Book", subjects: ["science"])

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue", %{"subject" => "fiction"})

      %{"books" => books, "total" => total} = json_response(conn, 200)
      assert total == 1
      assert List.first(books)["title"] == "Fiction Book"
    end

    test "paginates correctly", %{conn: conn} do
      user = insert(:user)

      for i <- 1..5 do
        insert_book_with_edition(title: "Book #{String.pad_leading(to_string(i), 2, "0")}")
      end

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue", %{"page" => "1", "per_page" => "2"})

      %{"books" => books, "total" => 5, "page" => 1, "per_page" => 2} =
        json_response(conn, 200)

      assert length(books) == 2
    end

    test "excludes age_gated books from unauthenticated catalogue listing", %{conn: conn} do
      insert_book_with_edition(title: "Normal Book", visibility_tier: "public")
      insert_book_with_edition(title: "Age Gated Book", visibility_tier: "age_gated")

      conn = get(conn, "/api/catalogue")

      %{"books" => books, "total" => total} = json_response(conn, 200)
      assert total == 1
      titles = Enum.map(books, & &1["title"])
      assert "Normal Book" in titles
      refute "Age Gated Book" in titles
    end

    test "total reflects age-gated exclusion — is accurate, not raw DB count", %{conn: conn} do
      insert_book_with_edition(title: "Public A", visibility_tier: "public")
      insert_book_with_edition(title: "Public B", visibility_tier: "public")
      insert_book_with_edition(title: "Public C", visibility_tier: "public")
      insert_book_with_edition(title: "Age Gated 1", visibility_tier: "age_gated")
      insert_book_with_edition(title: "Age Gated 2", visibility_tier: "age_gated")

      %{"books" => books, "total" => total} = json_response(get(conn, "/api/catalogue"), 200)
      assert total == 3
      assert length(books) == 3
    end

    test "authenticated user sees age_gated books in catalogue", %{conn: conn} do
      user = insert(:user, age_verified: true)
      insert_book_with_edition(title: "Age Gated Book", visibility_tier: "age_gated")

      %{"books" => books, "total" => total} =
        conn |> auth_conn(user) |> get("/api/catalogue") |> json_response(200)

      assert total == 1
      assert List.first(books)["title"] == "Age Gated Book"
    end

    test "excludes age_gated books for an authenticated-but-unverified user, total accurate",
         %{conn: conn} do
      # #229: an authenticated user who is NOT age-verified must be treated like
      # an anonymous viewer for age-gated listings — the books are omitted AND
      # `total` reflects the exclusion (SQL-level filter, not a post-filter that
      # would break pagination). Mirrors the anon total-correctness test above.
      user = insert(:user, age_verified: false)
      insert_book_with_edition(title: "Public A", visibility_tier: "public")
      insert_book_with_edition(title: "Public B", visibility_tier: "public")
      insert_book_with_edition(title: "Age Gated 1", visibility_tier: "age_gated")
      insert_book_with_edition(title: "Age Gated 2", visibility_tier: "age_gated")

      %{"books" => books, "total" => total} =
        conn |> auth_conn(user) |> get("/api/catalogue") |> json_response(200)

      assert total == 2
      assert length(books) == 2
      titles = Enum.map(books, & &1["title"])
      assert "Public A" in titles
      assert "Public B" in titles
      refute "Age Gated 1" in titles
      refute "Age Gated 2" in titles
    end

    test "returns author data when present", %{conn: conn} do
      user = insert(:user)
      author = insert(:author, name: "Jane Austen")
      insert_book_with_edition(title: "Pride and Prejudice", author: author)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue")

      %{"books" => [book]} = json_response(conn, 200)
      assert book["author"]["name"] == "Jane Austen"
    end

    test "multi-word search returns results without crashing", %{conn: conn} do
      user = insert(:user)
      author = insert(:author, name: "F. Scott Fitzgerald")
      insert_book_with_edition(title: "The Great Gatsby", author: author)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue", %{"search" => "great gatsby"})

      response = json_response(conn, 200)
      assert is_list(response["books"])
    end

    test "returns null author for books without an author", %{conn: conn} do
      user = insert(:user)
      insert_book_with_edition(title: "Anonymous Book")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/catalogue")

      %{"books" => [book]} = json_response(conn, 200)
      assert book["title"] == "Anonymous Book"
      assert is_nil(book["author"])
    end
  end
end
