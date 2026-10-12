defmodule StacksWeb.BookControllerTest do
  @moduledoc """
      Tests for GET /api/books/:id, GET /api/books/isbn/:isbn, POST /api/books,
      POST /api/books/confirm, and POST /api/books/:id/merge-format.
  """

  use CoreWeb.ConnCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.MockHttpClient
  alias Stacks.Workers.EnrichBookJob

  setup do
    :fuse.reset(:open_library_fuse)
    :fuse.reset(:google_books_fuse)
    :ok
  end

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp insert_book_with_edition(attrs \\ []) do
    book =
      insert(
        :book,
        Keyword.take(attrs, [:title, :visibility_tier, :author]) ++
          [editions: [build(:primary_book_edition, Keyword.take(attrs, [:isbn]))]]
      )

    {book, hd(book.editions)}
  end

  describe "GET /api/books/:id" do
    test "returns 200 with book JSON when book exists", %{conn: conn} do
      user = insert(:user)
      {book, edition} = insert_book_with_edition(title: "Middlemarch", visibility_tier: "public")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => returned, "placement" => nil} = json_response(conn, 200)
      assert returned["id"] == book.id
      assert returned["title"] == "Middlemarch"
      assert returned["visibility_tier"] == "public"
      assert returned["primary_edition"]["isbn"] == edition.isbn
      assert is_list(returned["editions"])
      assert returned["edition_count"] == 1
      assert is_integer(returned["community_read_count"])
    end

    test "returns placement data when user has an active placement for the book", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(title: "Placed Book", visibility_tier: "public")
      bookshelf = insert(:bookshelf, user: user, name: "library")
      insert(:placement, bookshelf: bookshelf, book: book)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => _, "placement" => placement} = json_response(conn, 200)
      assert placement["bookshelf_name"] == "library"
      assert is_binary(placement["id"])
      assert is_list(placement["formats"])
    end

    test "shelf ceiling set by name reaches the book-detail placement payload", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      insert(:placement, bookshelf: bookshelf, book: book)

      put_conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/visibility", %{"visibility" => "platform"})

      assert %{"visibility" => "platform"} = json_response(put_conn, 200)

      get_conn = build_conn() |> auth_conn(user) |> get("/api/books/#{book.id}")
      assert %{"placement" => placement} = json_response(get_conn, 200)
      assert placement["bookshelf_visibility"] == "platform"
    end

    test "returns 200 carrying BOTH placements when the book sits on two bookshelves",
         %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(title: "Middlemarch")
      library = insert(:bookshelf, user: user, name: "library")
      wishlist = insert(:bookshelf, user: user, name: "wishlist")
      insert(:placement, book: book, bookshelf: library)
      insert(:placement, book: book, bookshelf: wishlist)

      conn = conn |> auth_conn(user) |> get("/api/books/#{book.id}")

      assert %{"placements" => placements} = json_response(conn, 200)
      assert length(placements) == 2

      assert Enum.sort(Enum.map(placements, & &1["bookshelf_name"])) == ["library", "wishlist"]

      assert Enum.map(placements, & &1["id"]) |> Enum.uniq() |> length() == 2
    end

    test "the legacy singular placement key still names one of the two", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition()
      insert(:placement, book: book, bookshelf: insert(:bookshelf, user: user, name: "library"))
      insert(:placement, book: book, bookshelf: insert(:bookshelf, user: user, name: "wishlist"))

      conn = conn |> auth_conn(user) |> get("/api/books/#{book.id}")

      assert %{"placement" => placement, "placements" => [first | _]} = json_response(conn, 200)
      assert placement["id"] == first["id"]
    end

    test "another user's second placement of the same book does not leak in", %{conn: conn} do
      user = insert(:user)
      stranger = insert(:user)
      {book, _edition} = insert_book_with_edition()
      insert(:placement, book: book, bookshelf: insert(:bookshelf, user: user, name: "library"))

      insert(:placement,
        book: book,
        bookshelf: insert(:bookshelf, user: stranger, name: "wishlist")
      )

      conn = conn |> auth_conn(user) |> get("/api/books/#{book.id}")

      assert %{"placements" => [only]} = json_response(conn, 200)
      assert only["bookshelf_name"] == "library"
    end

    test "returns an empty placements list for a book the viewer has not placed", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition()

      conn = conn |> auth_conn(user) |> get("/api/books/#{book.id}")

      assert %{"placement" => nil, "placements" => []} = json_response(conn, 200)
    end

    test "returns 404 when book does not exist", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{Ecto.UUID.generate()}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 200 with null placement when not authenticated", %{conn: conn} do
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      conn = get(conn, "/api/books/#{book.id}")
      assert %{"book" => _, "placement" => nil} = json_response(conn, 200)
    end

    test "returns 403 for age_gated book when user is not age_verified", %{conn: conn} do
      user = insert(:user, age_verified: false)
      {book, _edition} = insert_book_with_edition(visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end

    test "returns 200 for age_gated book when user is age_verified", %{conn: conn} do
      user = insert(:user, age_verified: true)
      {book, _edition} = insert_book_with_edition(visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => _} = json_response(conn, 200)
    end
  end

  describe "PUT /api/books/:id/age-gate" do
    test "authed user marks a public book adults_only → 200 age_gated", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/books/#{book.id}/age-gate", %{"adults_only" => true})

      assert %{"book" => returned} = json_response(conn, 200)
      assert returned["id"] == book.id
      assert returned["visibility_tier"] == "age_gated"
    end

    test "attempting to LOWER an age_gated book → 403 (raise-only, owner-gated)", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/books/#{book.id}/age-gate", %{"adults_only" => false})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 401 without an auth token", %{conn: conn} do
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      conn = put(conn, "/api/books/#{book.id}/age-gate", %{"adults_only" => true})
      assert json_response(conn, 401)
    end

    test "returns 404 for a missing book", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/books/#{Ecto.UUID.generate()}/age-gate", %{"adults_only" => true})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "a resolver outage is a 503, not 'isbn_not_found'" do
    setup do
      MockHttpClient.put_response("openlibrary.org", {:error, :unexpected_status})
      MockHttpClient.put_response("googleapis.com", {:error, :unexpected_status})
      :ok
    end

    test "POST /api/books/confirm answers 503 resolver_unavailable", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565", "shelf_name" => "wishlist"})

      body = json_response(conn, 503)

      refute body["error"] == "isbn_not_found",
             "a 5xx from Open Library says nothing about whether 9780743273565 is a book"

      assert body["error"] == "resolver_unavailable"
      assert get_resp_header(conn, "retry-after") == ["30"]
    end

    test "POST /api/books/:id/merge-format answers 503 resolver_unavailable", %{conn: conn} do
      user = insert(:user)
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565")

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/#{book.id}/merge-format", %{"isbn" => "9780141036144"})

      assert %{"error" => "resolver_unavailable"} = json_response(conn, 503)
    end

    test "nothing is written when the resolver could not be reached", %{conn: conn} do
      user = insert(:user)
      before = Core.Repo.aggregate(Stacks.Books.Book, :count)

      conn
      |> auth_conn(user)
      |> post("/api/books/confirm", %{"isbn" => "9780743273565", "shelf_name" => "wishlist"})
      |> json_response(503)

      assert Core.Repo.aggregate(Stacks.Books.Book, :count) == before
    end
  end

  describe "an ISBN the catalogues denied is still 422 isbn_not_found" do
    setup do
      MockHttpClient.put_response("openlibrary.org", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})
      :ok
    end

    test "POST /api/books/confirm still answers 422", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565", "shelf_name" => "wishlist"})

      assert %{"error" => "isbn_not_found"} = json_response(conn, 422)
    end
  end

  describe "POST /api/books/confirm" do
    test "returns 200 with book data when ISBN resolves to existing book", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(isbn: "9780743273565")

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565"})

      assert %{"book" => returned, "placement" => placement} = json_response(conn, 200)
      assert returned["id"] == book.id
      assert placement["book_id"] == book.id
    end

    test "already owning the book elsewhere does not block the requested shelf", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(isbn: "9780743273565")
      insert(:placement, book: book, bookshelf: insert(:bookshelf, user: user, name: "library"))

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565", "shelf_name" => "wishlist"})

      assert %{"book" => returned, "placement" => placement, "placements" => placements} =
               json_response(conn, 200)

      assert returned["id"] == book.id
      assert placement["bookshelf_name"] == "wishlist"
      assert Enum.sort(Enum.map(placements, & &1["bookshelf_name"])) == ["library", "wishlist"]
    end

    test "confirming onto a bookshelf the book is already on is a no-op, not a duplicate", %{
      conn: conn
    } do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(isbn: "9780743273565")
      shelf = insert(:bookshelf, user: user, name: "library")
      existing = insert(:placement, book: book, bookshelf: shelf)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565", "shelf_name" => "library"})

      assert %{"placement" => placement, "placements" => placements, "source" => "collection"} =
               json_response(conn, 200)

      assert placement["id"] == existing.id
      assert length(placements) == 1
    end

    test "returns 201 with the resolved book when a new ISBN resolves via metadata (mocked)", %{
      conn: conn
    } do
      user = insert(:user)
      original = Application.get_env(:core, :isbn_http_client)

      try do
        Application.put_env(:core, :isbn_http_client, Stacks.Books.MockHttpClient)

        MockHttpClient.put_response("googleapis.com", {
          :ok,
          %{
            "items" => [
              %{
                "id" => "mock-id",
                "volumeInfo" => %{
                  "title" => "Confirm Test Book",
                  "authors" => ["Mock Author"],
                  "industryIdentifiers" => [
                    %{"type" => "ISBN_13", "identifier" => "9780451524935"}
                  ]
                }
              }
            ]
          }
        })

        conn =
          conn
          |> auth_conn(user)
          |> post("/api/books/confirm", %{"isbn" => "9780451524935", "shelf_name" => "library"})

        assert conn.status == 201

        assert %{"book" => book, "placement" => placement, "placements" => placements} =
                 json_response(conn, 201)

        assert book["title"] == "Confirm Test Book"

        assert placement["bookshelf_name"] == "library"
        assert Enum.map(placements, & &1["bookshelf_name"]) == ["library"]
        assert book["primary_edition"]["isbn"] == "9780451524935"
      after
        Application.put_env(:core, :isbn_http_client, original)
      end
    end

    test "returns 409 with merge_required when vision finds a matching work", %{conn: conn} do
      user = insert(:user)

      author = insert(:author, name: "George Orwell")
      book = insert(:book, title: "Nineteen Eighty-Four", author: author)
      insert(:book_edition, book: book, isbn: "9780141036144")

      original = Application.get_env(:core, :isbn_http_client)

      try do
        Application.put_env(:core, :isbn_http_client, Stacks.Books.MockHttpClient)

        MockHttpClient.put_response("googleapis.com", {
          :ok,
          %{
            "items" => [
              %{
                "id" => "mock-1984-id",
                "volumeInfo" => %{
                  "title" => "Nineteen Eighty-Four",
                  "authors" => ["George Orwell"],
                  "industryIdentifiers" => [
                    %{"type" => "ISBN_13", "identifier" => "9780451524935"}
                  ]
                }
              }
            ]
          }
        })

        works_before = Core.Repo.aggregate(Stacks.Books.Book, :count)

        conn =
          conn
          |> auth_conn(user)
          |> post("/api/books/confirm", %{"isbn" => "9780451524935"})

        assert %{"error" => "merge_required", "work_id" => work_id} = json_response(conn, 409)
        assert work_id == book.id

        assert Core.Repo.aggregate(Stacks.Books.Book, :count) == works_before

        refute Core.Repo.exists?(
                 from(e in Stacks.Books.BookEdition, where: e.isbn == "9780451524935")
               )
      after
        Application.put_env(:core, :isbn_http_client, original)
      end
    end

    test "returns 201 with the resolved book when Open Library is the source", %{conn: conn} do
      user = insert(:user)
      original = Application.get_env(:core, :isbn_http_client)

      try do
        Application.put_env(:core, :isbn_http_client, Stacks.Books.MockHttpClient)

        MockHttpClient.put_response(
          "openlibrary.org/api/books",
          {:ok,
           %{
             "ISBN:9780743273565" => %{
               "title" => "The Great Gatsby",
               "authors" => [%{"name" => "F. Scott Fitzgerald"}],
               "publish_date" => "1925",
               "number_of_pages" => 180,
               "subjects" => ["American fiction"],
               "key" => "/works/OL468431W"
             }
           }}
        )

        conn =
          conn
          |> auth_conn(user)
          |> post("/api/books/confirm", %{"isbn" => "9780743273565", "shelf_name" => "library"})

        assert %{"book" => book} = json_response(conn, 201)
        assert book["title"] == "The Great Gatsby"
        assert is_binary(book["id"])
      after
        Application.put_env(:core, :isbn_http_client, original)
      end
    end

    test "returns 422 when the ISBN has an invalid checksum", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273560"})

      assert %{"error" => "validation_failed", "details" => details} = json_response(conn, 422)
      assert %{"isbn" => ["has an invalid checksum"]} = details
    end

    test "an ISBN that fails the checksum is refused without asking the catalogues", %{conn: conn} do
      user = insert(:user)

      MockHttpClient.put_response("openlibrary.org", {:error, :unexpected_status})
      MockHttpClient.put_response("googleapis.com", {:error, :unexpected_status})

      reachable =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565"})

      assert %{"error" => "resolver_unavailable"} = json_response(reachable, 503),
             "the outage stubs must be in force, or the next assertion proves nothing"

      refused =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273560"})

      assert %{"error" => "validation_failed"} = json_response(refused, 422),
             "the same outage answered 503 for a well-formed ISBN, so a 422 here can " <>
               "only mean 9780743273560 was refused before either catalogue was asked"
    end

    test "returns 401 without auth token", %{conn: conn} do
      conn = post(conn, "/api/books/confirm", %{"isbn" => "9780743273565"})
      assert json_response(conn, 401)
    end

    test "returns 422 when isbn param is missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{})

      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "POST /api/books/:id/merge-format" do
    setup do
      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:9780141036144" => %{
            "title" => "Nineteen Eighty-Four",
            "authors" => [%{"name" => "George Orwell"}],
            "publish_date" => "1949",
            "number_of_pages" => 328,
            "subjects" => [],
            "key" => "/works/OL1168007W"
          },
          "ISBN:9780743273565" => %{
            "title" => "The Great Gatsby",
            "authors" => [%{"name" => "F. Scott Fitzgerald"}],
            "publish_date" => "1925",
            "number_of_pages" => 180,
            "subjects" => [],
            "key" => "/works/OL468431W"
          }
        }
      })

      :ok
    end

    test "returns 200 with edition data when adding a new edition to an existing book", %{
      conn: conn
    } do
      user = insert(:user)
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565")

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/#{book.id}/merge-format", %{
          "isbn" => "9780141036144",
          "format_label" => "Paperback"
        })

      assert %{"edition" => edition} = json_response(conn, 200)
      assert edition["isbn"] == "9780141036144"
    end

    test "returns 422 when ISBN is already registered to this book", %{conn: conn} do
      user = insert(:user)
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565")

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/#{book.id}/merge-format", %{"isbn" => "9780743273565"})

      assert %{"error" => "duplicate_isbn"} = json_response(conn, 422)
    end

    test "returns 404 when book_id does not exist", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/#{Ecto.UUID.generate()}/merge-format", %{
          "isbn" => "9780743273565"
        })

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 without auth token", %{conn: conn} do
      book = insert(:book)

      conn =
        post(conn, "/api/books/#{book.id}/merge-format", %{"isbn" => "9780743273565"})

      assert json_response(conn, 401)
    end
  end

  describe "GET /api/books/isbn/:isbn" do
    test "returns 200 when book with ISBN exists", %{conn: conn} do
      user = insert(:user)

      {book, _edition} =
        insert_book_with_edition(isbn: "9780451524935", visibility_tier: "public")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/isbn/9780451524935")

      assert %{"book" => returned} = json_response(conn, 200)
      assert returned["primary_edition"]["isbn"] == "9780451524935"
      assert returned["id"] == book.id
    end

    test "carries the viewer's existing placements so the client can say 'already yours'",
         %{conn: conn} do
      user = insert(:user)

      {book, _edition} =
        insert_book_with_edition(isbn: "9780451524935", visibility_tier: "public")

      insert(:placement, book: book, bookshelf: insert(:bookshelf, user: user, name: "library"))
      insert(:placement, book: book, bookshelf: insert(:bookshelf, user: user, name: "wishlist"))

      conn = conn |> auth_conn(user) |> get("/api/books/isbn/9780451524935")

      assert %{"book" => _, "placements" => placements} = json_response(conn, 200)
      assert Enum.sort(Enum.map(placements, & &1["bookshelf_name"])) == ["library", "wishlist"]
    end

    test "reports no placements for a book the viewer has never shelved", %{conn: conn} do
      user = insert(:user)
      insert_book_with_edition(isbn: "9780451524935", visibility_tier: "public")

      conn = conn |> auth_conn(user) |> get("/api/books/isbn/9780451524935")

      assert %{"placement" => nil, "placements" => []} = json_response(conn, 200)
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
      insert_book_with_edition(isbn: "9781600000126", visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/isbn/9781600000126")

      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end
  end

  describe "GET /api/books/:id — visibility gates" do
    test "age_gated book returns 403 for unauthenticated viewer" do
      {book, _edition} = insert_book_with_edition(visibility_tier: "age_gated")
      conn = build_conn() |> get("/api/books/#{book.id}")
      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end

    test "public book returns 200 for unauthenticated viewer" do
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      conn = build_conn() |> get("/api/books/#{book.id}")
      assert %{"book" => returned} = json_response(conn, 200)
      assert returned["id"] == book.id
    end

    test "public book returns 200 for authenticated viewer", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => returned} = json_response(conn, 200)
      assert returned["id"] == book.id
    end
  end

  describe "GET /api/books/:id — my_writing" do
    test "authenticated user with associated posts sees my_writing", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      blog_post = insert(:post, user: user, title: "My Review", published_at: DateTime.utc_now())
      {:ok, _assoc} = Stacks.Blog.associate_book(blog_post, book.id, %{visible: true})

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => _, "my_writing" => my_writing} = json_response(conn, 200)
      assert length(my_writing) == 1
      assert hd(my_writing)["title"] == "My Review"
    end

    test "authenticated user with no associations sees empty my_writing", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert %{"book" => _, "my_writing" => my_writing} = json_response(conn, 200)
      assert my_writing == []
    end

    test "unauthenticated user sees empty my_writing array", %{conn: conn} do
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")

      conn = get(conn, "/api/books/#{book.id}")

      assert %{"book" => _, "my_writing" => my_writing} = json_response(conn, 200)
      assert my_writing == []
    end
  end

  describe "GET /api/books/:id — hidden book is not served" do
    test "age-gated book (hidden to an unverified viewer) is refused and leaks no payload", %{
      conn: conn
    } do
      user = insert(:user, age_verified: false)

      {book, _edition} =
        insert_book_with_edition(title: "Restricted", visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      body = json_response(conn, 403)
      assert body == %{"error" => "age_verification_required"}
      refute Map.has_key?(body, "book")
      refute conn.resp_body =~ "Restricted"
    end

    test "age-gated book is refused for an unauthenticated viewer", %{conn: conn} do
      {book, _edition} = insert_book_with_edition(visibility_tier: "age_gated")

      conn = get(conn, "/api/books/#{book.id}")

      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end
  end

  describe "GET /api/books/:id — no events on read" do
    test "a successful read emits no event_log rows", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")

      before_count = total_event_count()

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/#{book.id}")

      assert json_response(conn, 200)["book"]["id"] == book.id
      assert total_event_count() == before_count
    end

    test "an unauthenticated read emits no event_log rows", %{conn: conn} do
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")

      before_count = total_event_count()

      conn = get(conn, "/api/books/#{book.id}")

      assert json_response(conn, 200)["book"]["id"] == book.id
      assert total_event_count() == before_count
    end
  end

  describe "GET /api/books/:id — cache miss then hit" do
    setup do
      test_pid = self()
      handler_id = "test-book-detail-cache-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:stacks, :book_detail_cache, :miss],
          [:stacks, :book_detail_cache, :hit]
        ],
        fn name, measurements, metadata, _ ->
          send(test_pid, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "first GET misses and caches; second GET hits", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      BookDetailCache.invalidate(book.id)

      conn1 = build_conn() |> auth_conn(user) |> get("/api/books/#{book.id}")
      assert json_response(conn1, 200)["book"]["id"] == book.id

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :miss], %{count: 1},
                      %{
                        book_id: book_id
                      }},
                     1_000

      assert book_id == book.id

      conn2 = build_conn() |> auth_conn(user) |> get("/api/books/#{book.id}")
      assert json_response(conn2, 200)["book"]["id"] == book.id

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :hit], %{count: 1},
                      %{
                        book_id: ^book_id
                      }},
                     1_000

      refute_receive {:telemetry, [:stacks, :book_detail_cache, :miss], _, _}, 200
    end
  end

  describe "POST /api/books/:id/merge-format then GET /api/books/:id" do
    test "the merged edition is visible on the next read of the book" do
      user = insert(:user)

      book =
        insert(:book,
          title: "The Name of the Rose",
          author: insert(:author, name: "Umberto Eco"),
          editions: [build(:primary_book_edition, isbn: "9780156030410")]
        )

      BookDetailCache.invalidate(book.id)

      original = Application.get_env(:core, :isbn_http_client)

      try do
        Application.put_env(:core, :isbn_http_client, MockHttpClient)

        MockHttpClient.put_response("googleapis.com", {
          :ok,
          %{
            "items" => [
              %{
                "id" => "mock-rose-vintage",
                "volumeInfo" => %{
                  "title" => "The Name of the Rose",
                  "authors" => ["Umberto Eco"],
                  "industryIdentifiers" => [
                    %{"type" => "ISBN_13", "identifier" => "9780099466031"}
                  ]
                }
              }
            ]
          }
        })

        before_body =
          build_conn()
          |> auth_conn(user)
          |> get("/api/books/#{book.id}")
          |> json_response(200)

        assert before_body["book"]["edition_count"] == 1

        merge_body =
          build_conn()
          |> auth_conn(user)
          |> post("/api/books/#{book.id}/merge-format", %{
            "isbn" => "9780099466031",
            "format_label" => "Paperback"
          })
          |> json_response(200)

        assert merge_body["edition"]["isbn"] == "9780099466031"

        assert Core.Repo.aggregate(
                 from(e in Stacks.Books.BookEdition, where: e.book_id == ^book.id),
                 :count
               ) == 2

        Oban.drain_queue(queue: :events)

        after_body =
          build_conn()
          |> auth_conn(user)
          |> get("/api/books/#{book.id}")
          |> json_response(200)

        assert after_body["book"]["edition_count"] == 2,
               "GET /api/books/:id served a stale work after a 200 merge — " <>
                 "the reader is shown a book without the edition they just added"

        assert "9780099466031" in Enum.map(after_body["book"]["editions"], & &1["isbn"])
      after
        Application.put_env(:core, :isbn_http_client, original)
      end
    end
  end

  describe "PUT /api/books/:id/age-gate then GET /api/books/:id" do
    test "the raised gate is enforced on the very next read, not when the TTL expires" do
      reader = insert(:user, age_verified: false)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      BookDetailCache.invalidate(book.id)

      before_body =
        build_conn()
        |> auth_conn(reader)
        |> get("/api/books/#{book.id}")
        |> json_response(200)

      assert before_body["book"]["visibility_tier"] == "public"

      marked =
        build_conn()
        |> auth_conn(insert(:user))
        |> put("/api/books/#{book.id}/age-gate", %{"adults_only" => true})
        |> json_response(200)

      assert marked["book"]["visibility_tier"] == "age_gated"

      assert %{"error" => "age_verification_required"} =
               build_conn()
               |> auth_conn(reader)
               |> get("/api/books/#{book.id}")
               |> json_response(403),
             "a book raised to age_gated was still served to a non-verified reader — " <>
               "the age gate is being enforced against the cached pre-gate copy"
    end
  end

  describe "EnrichBookJob then GET /api/books/:id" do
    test "the enriched title is visible on the next read, not after the TTL" do
      user = insert(:user)
      isbn = "9780451524935"

      {book, _edition} =
        insert_book_with_edition(title: "ISBN #{isbn}", isbn: isbn, visibility_tier: "public")

      BookDetailCache.invalidate(book.id)

      original = Application.get_env(:core, :isbn_http_client)

      try do
        Application.put_env(:core, :isbn_http_client, MockHttpClient)

        MockHttpClient.put_response(
          "openlibrary.org/api/books",
          {:ok,
           %{
             "ISBN:#{isbn}" => %{
               "title" => "Nineteen Eighty-Four",
               "authors" => [%{"name" => "George Orwell"}],
               "publishers" => [%{"name" => "Signet Classics"}]
             }
           }}
        )

        assert build_conn()
               |> auth_conn(user)
               |> get("/api/books/#{book.id}")
               |> json_response(200)
               |> get_in(["book", "title"]) == "ISBN #{isbn}"

        assert :ok = EnrichBookJob.perform(%Oban.Job{args: %{"isbn" => isbn}})

        Oban.drain_queue(queue: :events)

        assert build_conn()
               |> auth_conn(user)
               |> get("/api/books/#{book.id}")
               |> json_response(200)
               |> get_in(["book", "title"]) == "Nineteen Eighty-Four",
               "GET /api/books/:id still served the placeholder title after enrichment — " <>
                 "BookDetailCache was never evicted"
      after
        Application.put_env(:core, :isbn_http_client, original)
      end
    end
  end

  defp total_event_count do
    Core.Repo.aggregate(from(e in "event_log", prefix: "op"), :count)
  end
end
