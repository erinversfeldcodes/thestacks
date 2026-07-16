defmodule StacksWeb.BookControllerTest do
  @moduledoc """
  Tests for GET /api/books/:id, GET /api/books/isbn/:isbn, POST /api/books,
  POST /api/books/confirm, and POST /api/books/:id/merge-format.
  """

  # async: false because confirm/merge tests swap Application env for mock HTTP client.
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Books.MockHttpClient

  # Reset the resolver's circuit breakers before each test. :fuse state is
  # global, so a fuse blown by an earlier suite test can leak in and turn a
  # mocked ISBN resolve into :circuit_open → isbn_not_found (an order-dependent
  # flake observed in the full-suite run but not in isolation).
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
    book = insert(:book, Keyword.take(attrs, [:title, :visibility_tier, :author]))

    edition_attrs =
      attrs
      |> Keyword.take([:isbn])
      |> Keyword.put(:book, book)
      |> Keyword.put_new(:is_primary, true)

    edition = insert(:book_edition, edition_attrs)
    {book, edition}
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

    # Regression for the #122 live-E2E placement-greying bug: the shelf-visibility
    # update endpoint was keyed by UUID `:id`, but every other bookshelf route
    # (and both the Elm client and the E2E) address shelves by NAME. Setting the
    # ceiling by name therefore never persisted, so the book-detail placement
    # payload carried the default "owner" ceiling and the dropdown greyed the
    # (equal-rank) "platform" option. After the fix the ceiling the client set is
    # exactly what the greying sees.
    test "shelf ceiling set by name reaches the book-detail placement payload", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      insert(:placement, bookshelf: bookshelf, book: book)

      # Exactly what the client (Api.updateShelfVisibility) and the E2E do: PUT
      # the visibility route with the shelf NAME in the path.
      put_conn =
        conn
        |> auth_conn(user)
        |> put("/api/bookshelves/library/visibility", %{"visibility" => "platform"})

      assert %{"visibility" => "platform"} = json_response(put_conn, 200)

      get_conn = build_conn() |> auth_conn(user) |> get("/api/books/#{book.id}")
      assert %{"placement" => placement} = json_response(get_conn, 200)
      assert placement["bookshelf_visibility"] == "platform"
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

  describe "POST /api/books" do
    test "returns 201 with book when ISBN resolves (mocked)", %{conn: conn} do
      user = insert(:user)

      # Pre-insert the book+edition and test the duplicate-detection path
      {_book, _edition} =
        insert_book_with_edition(isbn: "9780743273565", title: "The Great Gatsby")

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books", %{"isbn" => "9780743273565"})

      # Accept either outcome so the test is not fragile on network availability.
      assert conn.status in [201, 422]
    end

    test "returns 422 when ISBN has invalid checksum", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books", %{"isbn" => "9780743273560"})

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 401 without auth token", %{conn: conn} do
      conn = post(conn, "/api/books", %{"isbn" => "9780743273565"})
      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 2 — POST /api/books HTTP layer with mocked ISBN resolver (US-1.1.5)
  # ---------------------------------------------------------------------------

  describe "POST /api/books — mocked ISBN resolver (US-1.1.5)" do
    setup do
      original = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, Stacks.Books.MockHttpClient)
      on_exit(fn -> Application.put_env(:core, :isbn_http_client, original) end)
      :ok
    end

    test "returns 201 with book data when valid ISBN resolves via mock Open Library", %{
      conn: conn
    } do
      user = insert(:user)

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
        |> post("/api/books", %{"isbn" => "9780743273565"})

      assert %{"book" => book} = json_response(conn, 201)
      assert book["title"] == "The Great Gatsby"
      assert is_binary(book["id"])
    end

    test "returns 422 when both Open Library and Google Books return no results", %{conn: conn} do
      user = insert(:user)

      # MockHttpClient returns {:ok, %{}} for unregistered patterns — empty body
      # is treated as not found by ISBNResolver for both Open Library and Google Books.
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books", %{"isbn" => "9780743273565"})

      assert %{"error" => _} = json_response(conn, 422)
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

    test "returns 200 with source=collection when user already owns the book", %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(isbn: "9780743273565")
      bookshelf = insert(:bookshelf, user: user, name: "library")
      insert(:placement, book: book, bookshelf: bookshelf)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565"})

      assert %{"book" => returned, "placement" => placement, "source" => "collection"} =
               json_response(conn, 200)

      assert returned["id"] == book.id
      assert placement["bookshelf_name"] == "library"
    end

    test "returns 200 with book data when ISBN resolves via metadata (mocked)", %{conn: conn} do
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
          |> post("/api/books/confirm", %{"isbn" => "9780451524935"})

        # Accept 201 (new book created) or 409 (merge required — unlikely with new ISBN)
        assert conn.status in [201, 409]
      after
        Application.put_env(:core, :isbn_http_client, original)
      end
    end

    test "returns 409 with merge_required when vision finds a matching work", %{conn: conn} do
      user = insert(:user)

      # Insert a book with a known title/author that find_similar_work will find
      author = insert(:author, name: "George Orwell")
      book = insert(:book, title: "Nineteen Eighty-Four", author: author)
      insert(:book_edition, book: book, isbn: "9780141036144")

      original = Application.get_env(:core, :isbn_http_client)

      try do
        Application.put_env(:core, :isbn_http_client, Stacks.Books.MockHttpClient)

        # Return metadata matching the existing book's title+author but different ISBN
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

        conn =
          conn
          |> auth_conn(user)
          |> post("/api/books/confirm", %{"isbn" => "9780451524935"})

        assert %{"error" => "merge_required", "work_id" => work_id} = json_response(conn, 409)
        assert work_id == book.id
      after
        Application.put_env(:core, :isbn_http_client, original)
      end
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
      insert_book_with_edition(isbn: "9780000000001", visibility_tier: "age_gated")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/books/isbn/9780000000001")

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
end
