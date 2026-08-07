defmodule StacksWeb.BookControllerTest do
  @moduledoc """
  Tests for GET /api/books/:id, GET /api/books/isbn/:isbn, POST /api/books,
  POST /api/books/confirm, and POST /api/books/:id/merge-format.
  """

  # async: false because confirm/merge tests swap Application env for mock HTTP client.
  use CoreWeb.ConnCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.MockHttpClient
  alias Stacks.Workers.EnrichBookJob

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

    # ── #333 regression: the multi-shelf 500 ────────────────────────────────
    #
    # A book may legally sit on several bookshelves at once (owner ruling,
    # 2026-07-30). The detail lookup fed its query to `Repo.one()`, so the
    # SECOND placement turned the owner's own book detail into an
    # `Ecto.MultipleResultsError` — a live 500 driven on 2026-07-30.
    #
    # The fixture is a genuine two-shelf state and not a factory artefact:
    # two bookshelves, ONE book, one placement on each. Factories are honest
    # since #329 (`insert(:placement)` derives its shelf from its bookshelf),
    # so this is exactly the row shape `Shelving.place_book/3` writes.
    test "returns 200 carrying BOTH placements when the book sits on two bookshelves",
         %{conn: conn} do
      user = insert(:user)
      {book, _edition} = insert_book_with_edition(title: "Middlemarch")
      library = insert(:bookshelf, user: user, name: "library")
      wishlist = insert(:bookshelf, user: user, name: "wishlist")
      insert(:placement, book: book, bookshelf: library)
      insert(:placement, book: book, bookshelf: wishlist)

      conn = conn |> auth_conn(user) |> get("/api/books/#{book.id}")

      # The status assertion is the regression: before the fix this raised out
      # of the controller rather than rendering anything at all.
      assert %{"placements" => placements} = json_response(conn, 200)
      assert length(placements) == 2

      assert Enum.sort(Enum.map(placements, & &1["bookshelf_name"])) == ["library", "wishlist"]

      # Every placement carries its own id, so the overlay can offer a remove
      # per shelf rather than one ambiguous "remove from my collection".
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

  # ---------------------------------------------------------------------------
  # #344 — a resolver outage is reported as an outage, on every write path
  # ---------------------------------------------------------------------------
  #
  # All three of these endpoints ended in `{:error, _} -> 422 "isbn_not_found"`.
  # That branch caught the reason nobody had classified, and the one thing it
  # could not distinguish is the one thing the reader most needs distinguished:
  # "we asked, and this is not a book" from "we could not ask". The second is a
  # fault of ours, the ISBN they typed may be perfectly good, and telling them
  # to check the number sends them to re-read a barcode that was right.
  describe "a resolver outage is a 503, not 'isbn_not_found' (#344)" do
    setup do
      # A 5xx from BOTH upstreams. `race_resolve/1` hands back the last error,
      # so `ISBNResolver.resolve/1` returns `{:error, :unexpected_status}` —
      # `:unavailable`, not `:not_found`.
      MockHttpClient.put_response("openlibrary.org", {:error, :unexpected_status})
      MockHttpClient.put_response("googleapis.com", {:error, :unexpected_status})
      :ok
    end

    test "POST /api/books answers 503 resolver_unavailable", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books", %{"isbn" => "9780743273565"})

      body = json_response(conn, 503)

      refute body["error"] == "isbn_not_found",
             "a 5xx from Open Library says nothing about whether 9780743273565 is a book"

      assert body["error"] == "resolver_unavailable"
      assert get_resp_header(conn, "retry-after") == ["30"]
    end

    test "POST /api/books/confirm answers 503 resolver_unavailable", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/books/confirm", %{"isbn" => "9780743273565", "shelf_name" => "wishlist"})

      assert %{"error" => "resolver_unavailable"} = json_response(conn, 503)
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
      # The negative half: an outage must not leave a half-identified book
      # behind for the catalogue to inherit.
      user = insert(:user)
      before = Core.Repo.aggregate(Stacks.Books.Book, :count)

      conn
      |> auth_conn(user)
      |> post("/api/books", %{"isbn" => "9780743273565"})
      |> json_response(503)

      assert Core.Repo.aggregate(Stacks.Books.Book, :count) == before
    end
  end

  describe "an ISBN the catalogues denied is still 422 isbn_not_found (#344)" do
    # The control that keeps the 503 honest. When the upstreams DO answer and
    # neither knows the ISBN, that IS a fact about the ISBN, and 422 is right.
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

    # ⚠️ #333 — this test used to assert `source: "collection"` for a book the
    # user owned on a DIFFERENT bookshelf from the one being confirmed onto.
    # That encoded the pre-ruling assumption that any existing placement means
    # "already placed": confirming a library book onto your Wish List quietly
    # did nothing and reported success. The owner's ruling (2026-07-30) makes
    # the multi-shelf state legal and says to inform, never block — so the
    # placement is now made and the OTHER shelves are reported alongside it.
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
      # The placement this request produced is the one that was asked for …
      assert placement["bookshelf_name"] == "wishlist"
      # … and the response tells the reader about the shelf they already had it
      # on, so the client can inform without having to ask again.
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

      # Same row, not a second copy on the same bookshelf — the state rung 4's
      # `bookshelf_placements_book_active_idx` forbids and the ruling keeps
      # forbidden.
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

        # ⚠️ This was `assert conn.status in [201, 409]` with the comment
        # "accept 201 (new book created) or 409 (merge required — unlikely with
        # a new ISBN)" (Issue #330). 201 and 409 are the two OPPOSITE outcomes
        # of this endpoint — "created it" and "refused, you must merge" — so the
        # disjunction passed whichever happened and asserted only "not a crash".
        # It would have gone green if metadata resolution silently started
        # colliding every new ISBN with an existing work.
        #
        # The test means 201: this user's collection is empty, the only seeded
        # row is the user, and 9780451524935 exists nowhere — so there is no
        # work for `find_similar_work` to match and a merge can never be
        # required. The old comment said as much ("unlikely with new ISBN") and
        # then hedged anyway.
        assert conn.status == 201

        assert %{"book" => book, "placement" => placement, "placements" => placements} =
                 json_response(conn, 201)

        assert book["title"] == "Confirm Test Book"

        # The manual-entry path (#343) has no separate "now file it" call to
        # fall back on — `confirm/2` creates the work, its primary edition and
        # the placement in one transaction, so a 201 that resolved the metadata
        # but placed nothing (or placed it on the default bookshelf rather than
        # the requested one) would leave the reader's add silently half-done.
        assert placement["bookshelf_name"] == "library"
        assert Enum.map(placements, & &1["bookshelf_name"]) == ["library"]
        assert book["primary_edition"]["isbn"] == "9780451524935"
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

        works_before = Core.Repo.aggregate(Stacks.Books.Book, :count)

        conn =
          conn
          |> auth_conn(user)
          |> post("/api/books/confirm", %{"isbn" => "9780451524935"})

        assert %{"error" => "merge_required", "work_id" => work_id} = json_response(conn, 409)
        assert work_id == book.id

        # W-13 (the two-Name-of-the-Rose defect) in its regression form. The
        # 409 alone only proves the endpoint said "merge"; what the campaign
        # found live was a SECOND work sitting in the catalogue next to the
        # first. `merge_required` has to be a refusal, not a warning issued on
        # the way to creating one anyway.
        assert Core.Repo.aggregate(Stacks.Books.Book, :count) == works_before

        # …and no edition was quietly attached either: merging is the client's
        # next call (`POST /api/books/:id/merge-format`), not a side effect of
        # being told to merge.
        refute Core.Repo.exists?(
                 from(e in Stacks.Books.BookEdition, where: e.isbn == "9780451524935")
               )
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

    # #333 — the manual-ISBN path's duplicate awareness. The photo path has had
    # `is_duplicate` in its SSE payload for a long time; typing the ISBN by hand
    # told the reader nothing, so they placed a second copy without knowing.
    # This is informational only: the lookup still succeeds, and nothing here
    # can refuse the placement that follows.
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

  # ---------------------------------------------------------------------------
  # GET /api/books/:id — hidden book is not served (Issue #114, punch #3)
  #
  # A book's ONLY server-side hidden state is the age gate (a book has no owner,
  # no block relationship, and its `visibility_tier` always resolves as "public"
  # for resource visibility — see Stacks.Visibility). `AgeGate.enforce/2`
  # intercepts an age-gated book for an unverified viewer with a 403 BEFORE the
  # controller's `resolve_visibility == :hidden -> 404` branch is reached, so the
  # reachable "hidden book" outcome is a 403 that leaks no book payload.
  # (The literal :hidden -> 404 branch is defensive/unreachable for books; flagged
  # in the Phase 2 report.)
  # ---------------------------------------------------------------------------

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
      # The hidden book's detail payload must not appear in a refusal response.
      refute Map.has_key?(body, "book")
      refute conn.resp_body =~ "Restricted"
    end

    test "age-gated book is refused for an unauthenticated viewer", %{conn: conn} do
      {book, _edition} = insert_book_with_edition(visibility_tier: "age_gated")

      conn = get(conn, "/api/books/#{book.id}")

      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/books/:id — read is side-effect free (Issue #114, punch #4 variant)
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # GET /api/books/:id — controller<->cache integration (Issue #114, punch #6)
  #
  # First read is a cache miss that populates BookDetailCache; the second read is
  # a hit served from cache. Proven via the [:stacks, :book_detail_cache, :*]
  # telemetry the cache emits (Phase 2 instrumentation), not by inspecting
  # internal cache state.
  # ---------------------------------------------------------------------------

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

      # First request: cold cache -> miss, then populated.
      conn1 = build_conn() |> auth_conn(user) |> get("/api/books/#{book.id}")
      assert json_response(conn1, 200)["book"]["id"] == book.id

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :miss], %{count: 1},
                      %{
                        book_id: book_id
                      }},
                     1_000

      assert book_id == book.id

      # Second request: warm cache -> hit.
      conn2 = build_conn() |> auth_conn(user) |> get("/api/books/#{book.id}")
      assert json_response(conn2, 200)["book"]["id"] == book.id

      assert_receive {:telemetry, [:stacks, :book_detail_cache, :hit], %{count: 1},
                      %{
                        book_id: ^book_id
                      }},
                     1_000

      # The warm read must NOT re-query/re-cache: no second miss is emitted.
      refute_receive {:telemetry, [:stacks, :book_detail_cache, :miss], _, _}, 200
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/books/:id/merge-format -> GET /api/books/:id (Issue #355)
  #
  # The boundary neither existing test crossed. #343's program tests assert the
  # merge REQUEST is made; #341's context tests assert `merge_edition/2`
  # PERSISTS. Both were true and both passed while the reader was shown a book
  # without the edition they had just merged into it — because BookDetailCache
  # sits between the two, and nothing invalidated it.
  #
  # So the test has to hold all three in one picture: read (which caches),
  # write, read again. Reading FIRST is the whole point; a test that merges into
  # a cold cache passes no matter how the invalidation is wired, or whether it
  # is wired at all.
  # ---------------------------------------------------------------------------

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

        # 1. The reader looks at the work — exactly what the merge prompt does
        #    (`Api.getBook workId`) to put the title in its sentence. This is
        #    what puts the pre-merge work in BookDetailCache.
        before_body =
          build_conn()
          |> auth_conn(user)
          |> get("/api/books/#{book.id}")
          |> json_response(200)

        assert before_body["book"]["edition_count"] == 1

        # 2. The merge the reader accepts.
        merge_body =
          build_conn()
          |> auth_conn(user)
          |> post("/api/books/#{book.id}/merge-format", %{
            "isbn" => "9780099466031",
            "format_label" => "Paperback"
          })
          |> json_response(200)

        assert merge_body["edition"]["isbn"] == "9780099466031"

        # The write landed, and landed on the SAME work — the merge itself was
        # never the defect and must not become one.
        assert Core.Repo.aggregate(
                 from(e in Stacks.Books.BookEdition, where: e.book_id == ^book.id),
                 :count
               ) == 2

        # 3. Oban delivers `books.edition_merged` to CacheInvalidationHandler.
        #    In production this is the events queue doing its job; here it is
        #    the same worker, run inline.
        Oban.drain_queue(queue: :events)

        # 4. "View Book" — the merge prompt's own follow-on action.
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

  # ---------------------------------------------------------------------------
  # The other two writes that changed a book and evicted nothing (Issue #357)
  #
  # Same shape as the merge probe above, for the same reason: read, write, read.
  # Both were found by driving a live database, and both are invisible to a test
  # that writes into a cold cache.
  #
  # The age-gate half is the serious one — it is an unenforced content-safety
  # control for the length of a cache TTL, not a stale title — so it is the one
  # that must pass with no queue drained.
  # ---------------------------------------------------------------------------

  describe "PUT /api/books/:id/age-gate then GET /api/books/:id" do
    test "the raised gate is enforced on the very next read, not when the TTL expires" do
      reader = insert(:user, age_verified: false)
      {book, _edition} = insert_book_with_edition(visibility_tier: "public")
      BookDetailCache.invalidate(book.id)

      # 1. The reader looks at the book while it is still public. This is the
      #    load-bearing step: it puts the PUBLIC work in BookDetailCache.
      before_body =
        build_conn()
        |> auth_conn(reader)
        |> get("/api/books/#{book.id}")
        |> json_response(200)

      assert before_body["book"]["visibility_tier"] == "public"

      # 2. Someone marks it adults-only.
      marked =
        build_conn()
        |> auth_conn(insert(:user))
        |> put("/api/books/#{book.id}/age-gate", %{"adults_only" => true})
        |> json_response(200)

      assert marked["book"]["visibility_tier"] == "age_gated"

      # 3. The same reader comes back — and note what is NOT here: the
      #    `Oban.drain_queue(queue: :events)` the merge probe needs. The eviction
      #    is synchronous exactly so the gate does not wait on the queue.
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

      # A barcode fast-path book: stored with a placeholder title, its real
      # metadata still owed by EnrichBookJob.
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

        # 1. The reader opens the book while enrichment is still in flight —
        #    which is precisely when this happens, and what caches the placeholder.
        assert build_conn()
               |> auth_conn(user)
               |> get("/api/books/#{book.id}")
               |> json_response(200)
               |> get_in(["book", "title"]) == "ISBN #{isbn}"

        # 2. The job lands the real metadata.
        assert :ok = EnrichBookJob.perform(%Oban.Job{args: %{"isbn" => isbn}})

        # 3. Oban delivers `book.enriched` to CacheInvalidationHandler. Unlike the
        #    age gate, eventual is the right latency for a title.
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
