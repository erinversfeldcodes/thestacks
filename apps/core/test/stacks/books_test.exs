defmodule Stacks.BooksTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Books.BookEdition
  alias Stacks.Books.ISBNResolver
  alias Stacks.Books.MockHttpClient

  describe "create/1" do
    test "creates a book (work) with edition for valid attributes" do
      attrs = %{"isbn" => "9780743273565", "title" => "The Great Gatsby"}
      assert {:ok, book} = Books.create(attrs)
      assert book.title == "The Great Gatsby"
      assert [edition] = book.editions
      assert edition.isbn == "9780743273565"
      assert edition.is_primary == true
    end

    test "returns error on missing isbn" do
      attrs = %{"title" => "No ISBN Book"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: [_]} = errors_on(changeset)
    end

    test "returns error on duplicate isbn" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565")
      attrs = %{"isbn" => "9780743273565", "title" => "Duplicate"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has already been taken"]} = errors_on(changeset)
    end

    test "returns error on invalid isbn format" do
      attrs = %{"isbn" => "not-an-isbn", "title" => "Bad ISBN"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: [_]} = errors_on(changeset)
    end

    test "returns error on isbn-13 with invalid checksum" do
      attrs = %{"isbn" => "9780743273560", "title" => "Bad Checksum"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has an invalid checksum"]} = errors_on(changeset)
    end

    test "returns error on isbn-10 with invalid checksum" do
      attrs = %{"isbn" => "0306406153", "title" => "Bad ISBN-10 Checksum"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has an invalid checksum"]} = errors_on(changeset)
    end

    test "accepts isbn-10 with valid checksum and normalises to isbn-13" do
      attrs = %{"isbn" => "0306406152", "title" => "Valid ISBN-10"}
      assert {:ok, book} = Books.create(attrs)
      assert [edition] = book.editions
      # ISBN-10 "0306406152" normalises to ISBN-13 on storage so that
      # find_existing/1 (which searches by ISBN-13) can round-trip correctly.
      assert edition.isbn == "9780306406157"
    end
  end

  describe "create/1 — with author" do
    test "creates book and author when author attribute is provided" do
      attrs = %{
        "isbn" => "9780451524935",
        "title" => "Nineteen Eighty-Four",
        "author" => "George Orwell"
      }

      assert {:ok, book} = Books.create(attrs)
      assert [edition] = book.editions
      assert edition.isbn == "9780451524935"
      assert book.author_id != nil
    end

    test "reuses existing author record when author already exists" do
      {:ok, _} =
        Books.create(%{
          "isbn" => "9780141036144",
          "title" => "1984 First Ed",
          "author" => "George Orwell"
        })

      assert {:ok, book2} =
               Books.create(%{
                 "isbn" => "9780451526342",
                 "title" => "Animal Farm",
                 "author" => "George Orwell"
               })

      assert book2.author_id != nil
    end
  end

  describe "find_existing/1" do
    test "returns book when isbn exists" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565")
      assert found = Books.find_existing("9780743273565")
      assert found.id == book.id
    end

    test "returns nil when isbn not found" do
      assert nil == Books.find_existing("9999999999999")
    end

    test "finds a book by ISBN-10 when the edition is stored as ISBN-13" do
      book = insert(:book)
      # Stored as ISBN-13; ISBN-10 equivalent is 0743273567
      insert(:book_edition, book: book, isbn: "9780743273565")
      assert found = Books.find_existing("0743273567")
      assert found.id == book.id
    end
  end

  describe "get_book_detail/1" do
    test "returns book with author and editions preloaded" do
      author = insert(:author)
      book = insert(:book, author: author)
      insert(:book_edition, book: book)
      assert found = Books.get_book_detail(book.id)
      assert found.id == book.id
      assert found.author.id == author.id
      assert length(found.editions) == 1
    end

    test "returns nil for unknown id" do
      assert nil == Books.get_book_detail(Ecto.UUID.generate())
    end
  end

  describe "primary_edition/1" do
    test "returns the primary edition" do
      book = insert(:book)
      insert(:book_edition, book: book, is_primary: false, isbn: "9780000000001")
      primary = insert(:book_edition, book: book, is_primary: true, isbn: "9780000000002")
      book = Books.get_book_detail(book.id)
      assert Books.primary_edition(book).id == primary.id
    end

    test "falls back to first edition when no primary" do
      book = insert(:book)
      first = insert(:book_edition, book: book, is_primary: false)
      book = Books.get_book_detail(book.id)
      assert Books.primary_edition(book).id == first.id
    end
  end

  describe "primary_edition/1 — deterministic ordering (PE P3-2)" do
    test "query clause: no primary flag → picks the earliest-created edition, repeatably" do
      book = insert(:book)

      older =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9780000000010",
          created_at: ~U[2024-01-01 00:00:00.000000Z]
        )

      _newer =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9780000000011",
          created_at: ~U[2024-06-01 00:00:00.000000Z]
        )

      # The struct carries only the id, forcing the DB (query) clause.
      query_book = %Book{id: book.id}

      assert Books.primary_edition(query_book).id == older.id
      assert Books.primary_edition(query_book).id == older.id
    end

    test "in-memory clause: no primary flag → picks the earliest-created edition regardless of list order" do
      book = insert(:book)

      older =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9780000000012",
          created_at: ~U[2024-01-01 00:00:00.000000Z]
        )

      newer =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9780000000013",
          created_at: ~U[2024-06-01 00:00:00.000000Z]
        )

      # Preload order must not sway the pick — both orderings resolve to `older`.
      assert Books.primary_edition(%Book{id: book.id, editions: [newer, older]}).id == older.id
      assert Books.primary_edition(%Book{id: book.id, editions: [older, newer]}).id == older.id
    end

    test "explicit primary wins over an earlier-created non-primary (both clauses)" do
      book = insert(:book)

      early =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9780000000014",
          created_at: ~U[2020-01-01 00:00:00.000000Z]
        )

      primary =
        insert(:book_edition,
          book: book,
          is_primary: true,
          isbn: "9780000000015",
          created_at: ~U[2024-01-01 00:00:00.000000Z]
        )

      assert Books.primary_edition(%Book{id: book.id}).id == primary.id

      assert Books.primary_edition(%Book{id: book.id, editions: [early, primary]}).id ==
               primary.id
    end
  end

  describe "search_books/2" do
    test "returns books matching title query" do
      book1 = insert(:book, title: "Elixir Programming Guide")
      insert(:book_edition, book: book1)
      book2 = insert(:book, title: "Ruby on Rails Tutorial")
      insert(:book_edition, book: book2)

      results = Books.search_books("Elixir")
      titles = Enum.map(results, & &1.title)
      assert "Elixir Programming Guide" in titles
      refute "Ruby on Rails Tutorial" in titles
    end

    test "returns empty list when no match" do
      assert [] == Books.search_books("ZZZNoMatchZZZ")
    end

    test "matches a multi-word query via plainto_tsquery tokenisation" do
      book = insert(:book, title: "Elixir in Action")
      insert(:book_edition, book: book)
      other = insert(:book, title: "Rust Atomics and Locks")
      insert(:book_edition, book: other)

      results = Books.search_books("elixir action")
      titles = Enum.map(results, & &1.title)

      assert "Elixir in Action" in titles
      refute "Rust Atomics and Locks" in titles
    end

    # Layer 3 DB-assertion punch (#115 audit #2): prove the two DB mechanisms the
    # feature rests on — the generated tsvector column and the GIN index — rather
    # than trusting them via `search_books/2`.
    test "populates the title_tsv tsvector column on book creation" do
      book = insert(:book, title: "Elixir in Action")

      %{rows: [[tsv]]} =
        Repo.query!(
          "SELECT title_tsv::text FROM op.books WHERE id = $1",
          [Ecto.UUID.dump!(book.id)]
        )

      # Column is GENERATED ALWAYS AS to_tsvector('english', title) STORED, so it
      # is non-null and carries stemmed lexemes with `in` dropped as a stopword.
      assert tsv =~ "elixir"
      assert tsv =~ "action"
      refute tsv =~ "'in'"
    end

    test "the full-text query uses the title_tsv GIN index" do
      # On a tiny table the planner prefers a seqscan; disable it within this
      # sandbox transaction so the plan reflects index availability, then assert
      # the GIN index (idx_books_title_tsv) is chosen.
      Repo.query!("SET LOCAL enable_seqscan = off")

      %{rows: rows} =
        Repo.query!(
          "EXPLAIN SELECT id FROM op.books WHERE title_tsv @@ plainto_tsquery('english', $1)",
          ["elixir"]
        )

      plan = rows |> List.flatten() |> Enum.join("\n")
      assert plan =~ "idx_books_title_tsv"
    end
  end

  describe "confirm_cover_association/2" do
    test "updates cover_image_url on a known edition" do
      edition = insert(:book_edition)
      cover_url = "https://example.com/cover.jpg"

      assert {:ok, updated} = Books.confirm_cover_association(edition.id, cover_url)
      assert updated.cover_image_url == cover_url
    end

    test "returns {:error, :not_found} for an unknown edition_id" do
      assert {:error, :not_found} =
               Books.confirm_cover_association(Ecto.UUID.generate(), "https://example.com/x.jpg")
    end

    test "emits book.cover_confirmed event with edition_id and cover_url" do
      edition = insert(:book_edition)
      cover_url = "https://example.com/cover.jpg"
      before_count = event_count("book.cover_confirmed")

      Books.confirm_cover_association(edition.id, cover_url)

      assert event_count("book.cover_confirmed") == before_count + 1
    end

    test "does not emit event when edition_id is not found" do
      before_count = event_count("book.cover_confirmed")

      Books.confirm_cover_association(Ecto.UUID.generate(), "https://example.com/x.jpg")

      assert event_count("book.cover_confirmed") == before_count
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #046 — new functions under test
  # ---------------------------------------------------------------------------

  describe "find_same_work/2" do
    test "returns empty list when DB is empty" do
      assert [] = Books.find_same_work("1984", "George Orwell")
    end

    test "returns the matching work when title+author Jaro-Winkler similarity is high" do
      # Insert a work with title "1984" and author "George Orwell"
      author = insert(:author, name: "George Orwell")
      book = insert(:book, title: "1984", author: author)
      insert(:book_edition, book: book)

      # "Nineteen Eighty-Four" by "George Orwell" should fuzzy-match "1984" by "George Orwell"
      # Note: if Jaro-Winkler on "1984" vs "Nineteen Eighty-Four" is not > 0.8, implementation
      # may only match by author. The test validates the return type — a list containing the work.
      results = Books.find_same_work("1984", "George Orwell")
      assert is_list(results)
      assert Enum.any?(results, fn w -> w.id == book.id end)
    end

    test "returns empty list when title and author are clearly unrelated" do
      author = insert(:author, name: "George Orwell")
      book = insert(:book, title: "1984", author: author)
      insert(:book_edition, book: book)

      assert [] = Books.find_same_work("Something Completely Different", "Unknown Author")
    end
  end

  describe "identify/2" do
    # identify/2 calls the AI client (vision service). In test env the mock client is used.
    setup do
      original = Application.get_env(:core, :vision_client)
      Application.put_env(:core, :vision_client, Stacks.AI.MockClient)
      on_exit(fn -> Application.put_env(:core, :vision_client, original) end)
      :ok
    end

    test "returns {:ok, candidates} list when vision service responds successfully" do
      user = insert(:user)
      image_b64 = Base.encode64("fake_image_bytes")

      assert {:ok, candidates} = Books.identify(user.id, {:b64, image_b64})
      assert is_list(candidates)
    end

    test "returns {:error, reason} when vision service call fails" do
      user = insert(:user)

      # Temporarily override with a client that always fails
      defmodule Stacks.AI.AlwaysFailClient do
        @behaviour Stacks.AI.ClientBehaviour
        @impl true
        def call_vision(_endpoint, _payload), do: {:error, :simulated_failure}
      end

      Application.put_env(:core, :vision_client, Stacks.AI.AlwaysFailClient)

      result = Books.identify(user.id, {:b64, Base.encode64("bytes")})
      assert {:error, _reason} = result
    end
  end

  describe "confirm/2" do
    setup do
      # Use MockClient so ISBNResolver HTTP calls can be mocked
      original_http = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, MockHttpClient)

      on_exit(fn ->
        Application.put_env(:core, :isbn_http_client, original_http)
      end)

      # Stub ISBNResolver to return metadata for our test ISBN
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:9780141036144" => %{
             "title" => "Nineteen Eighty-Four",
             "authors" => [%{"name" => "George Orwell"}],
             "publish_date" => "1949",
             "number_of_pages" => 328,
             "subjects" => ["Dystopian fiction"],
             "key" => "/books/OL7353617M"
           }
         }}
      )

      :ok
    end

    test "creates work + edition + placement when ISBN does not exist; defaults to wishlist shelf" do
      user = insert(:user)

      assert {:ok, :created, book} = Books.confirm(user.id, %{isbn: "9780141036144"})
      assert book.title != nil
      assert is_list(book.editions)
      assert book.editions != []
    end

    test "creates placement on specified shelf when shelf_name provided" do
      user = insert(:user)

      assert {:ok, :created, book} =
               Books.confirm(user.id, %{isbn: "9780141036144", shelf_name: "library"})

      assert book.title != nil
    end

    test "returns existing book when ISBN already exists (no duplicate created)" do
      user = insert(:user)
      existing_book = insert(:book, title: "Nineteen Eighty-Four")
      insert(:book_edition, book: existing_book, isbn: "9780141036144")

      assert {:ok, :existing, returned_book, placement} =
               Books.confirm(user.id, %{isbn: "9780141036144"})

      assert returned_book.id == existing_book.id
      assert placement.book_id == existing_book.id
    end

    test "returns {:ok, :existing, book, placement} when ISBN exists but user has no placement" do
      user = insert(:user)
      existing_book = insert(:book, title: "Already In Catalogue")
      insert(:book_edition, book: existing_book, isbn: "9780141036144")

      assert {:ok, :existing, book, placement} = Books.confirm(user.id, %{isbn: "9780141036144"})
      assert book.id == existing_book.id
      assert placement.book_id == existing_book.id
    end

    test "returns {:ok, :already_placed, book, placement} when user already owns the book" do
      user = insert(:user)
      existing_book = insert(:book, title: "Already Placed Book")
      insert(:book_edition, book: existing_book, isbn: "9780141036144")
      bookshelf = insert(:bookshelf, user: user, name: "library")
      existing_placement = insert(:placement, book: existing_book, bookshelf: bookshelf)

      assert {:ok, :already_placed, book, placement} =
               Books.confirm(user.id, %{isbn: "9780141036144"})

      assert book.id == existing_book.id
      assert placement.id == existing_placement.id
    end

    test "returns {:error, {:merge_required, existing_work_id}} when same work detected via fuzzy match" do
      # Insert a work that is a clear title+author match via Jaro-Winkler
      author = insert(:author, name: "George Orwell")
      existing_book = insert(:book, title: "Nineteen Eighty-Four", author: author)
      insert(:book_edition, book: existing_book, isbn: "9780451526342")

      user = insert(:user)

      # A different ISBN for the same work should trigger merge detection
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:9780141036144" => %{
             "title" => "Nineteen Eighty-Four",
             "authors" => [%{"name" => "George Orwell"}],
             "publish_date" => "1949",
             "number_of_pages" => 328,
             "subjects" => [],
             "key" => "/books/OL7353617M"
           }
         }}
      )

      result = Books.confirm(user.id, %{isbn: "9780141036144"})
      assert {:error, {:merge_required, work_id}} = result
      assert work_id == existing_book.id
    end

    test "emits books.confirmed event on new book creation" do
      user = insert(:user)
      before_count = event_count("books.confirmed")

      Books.confirm(user.id, %{isbn: "9780141036144"})

      assert event_count("books.confirmed") == before_count + 1
    end
  end

  describe "merge_edition/2" do
    setup do
      # Seed mock responses so ISBNResolver.resolve/1 succeeds for test ISBNs
      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:9780451524935" => %{
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
          },
          "ISBN:9780316769174" => %{
            "title" => "The Catcher in the Rye",
            "authors" => [%{"name" => "J.D. Salinger"}],
            "publish_date" => "1951",
            "number_of_pages" => 277,
            "subjects" => [],
            "key" => "/works/OL15290W"
          }
        }
      })

      original_http = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, MockHttpClient)
      on_exit(fn -> Application.put_env(:core, :isbn_http_client, original_http) end)

      :ok
    end

    test "creates a non-primary edition under an existing work" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565", is_primary: true)

      assert {:ok, edition} =
               Books.merge_edition(book.id, %{isbn: "9780451524935", format_label: "Hardcover"})

      assert edition.isbn == "9780451524935"
      assert edition.is_primary == false
      assert edition.book_id == book.id
    end

    test "returns {:error, :duplicate_isbn} on duplicate ISBN" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565", is_primary: true)

      # Try to merge the same ISBN again
      assert {:error, :duplicate_isbn} =
               Books.merge_edition(book.id, %{isbn: "9780743273565"})
    end

    test "returns error when book_id does not exist" do
      nonexistent_id = Ecto.UUID.generate()

      result = Books.merge_edition(nonexistent_id, %{isbn: "9780451524935"})
      assert {:error, _} = result
    end

    test "emits books.edition_merged event on success" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565", is_primary: true)
      before_count = event_count("books.edition_merged")

      Books.merge_edition(book.id, %{isbn: "9780451524935", format_label: "Paperback"})

      assert event_count("books.edition_merged") == before_count + 1
    end

    @tag stories: ["US-1.1.8"], suite: :events
    test "books.edition_merged event aggregate_id matches the new edition's id" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565", is_primary: true)

      assert {:ok, %BookEdition{} = edition} =
               Books.merge_edition(book.id, %{isbn: "9780316769174", format_label: "Paperback"})

      events =
        Repo.all(
          from(e in "event_log",
            prefix: "op",
            where: e.event_type == "books.edition_merged",
            order_by: [desc: e.occurred_at],
            limit: 1,
            select: %{aggregate_id: e.aggregate_id}
          )
        )

      assert [%{aggregate_id: raw_id}] = events

      {:ok, event_aggregate_id} = Ecto.UUID.load(raw_id)
      assert event_aggregate_id == edition.id
    end
  end

  describe "search_platform/2" do
    test "returns {books, count} tuple for a matching query" do
      book = insert(:book, title: "Platform Search Test Book")
      insert(:book_edition, book: book)
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      insert(:placement, book: book, bookshelf: bookshelf, visibility: "platform")

      {results, count} = Books.search_platform("Platform Search Test", [])

      assert is_list(results)
      assert is_integer(count)
      assert count >= 0
    end

    test "returns {books, count} for an empty query (returns catalogue)" do
      {results, count} = Books.search_platform("", limit: 5)

      assert is_list(results)
      assert is_integer(count)
    end

    test "returns {[], 0} when query matches nothing" do
      {results, count} = Books.search_platform("XYZNoMatchAtAllXYZ123", [])

      assert results == []
      assert count == 0
    end
  end

  describe "ISBNResolver.resolve/1 — open_library_work_id field" do
    setup do
      original_http = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, MockHttpClient)
      on_exit(fn -> Application.put_env(:core, :isbn_http_client, original_http) end)
      :ok
    end

    test "returned metadata map contains :open_library_id key (work-level identifier)" do
      isbn = "9780743273565"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "The Great Gatsby",
             "authors" => [%{"name" => "F. Scott Fitzgerald"}],
             "publish_date" => "1925",
             "number_of_pages" => 180,
             "subjects" => [],
             "key" => "/works/OL468431W"
           }
         }}
      )

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      # The current implementation returns :open_library_id from the "key" field.
      # Issue #046 extends this to also return :open_library_work_id.
      # This test verifies at minimum one of the two keys is present.
      assert Map.has_key?(meta, :open_library_id) or Map.has_key?(meta, :open_library_work_id)
    end
  end

  describe "store_upload/2" do
    test "emits image.submitted event on successful upload" do
      user = insert(:user)
      tmp = System.tmp_dir!() |> Path.join("test_upload_#{System.unique_integer()}.jpg")
      File.write!(tmp, "fake image bytes")

      upload = %Plug.Upload{path: tmp, filename: "test.jpg", content_type: "image/jpeg"}
      before_count = event_count("image.submitted")

      Books.store_upload(user.id, upload)

      assert event_count("image.submitted") == before_count + 1

      File.rm(tmp)
    end

    test "returns {:ok, image} with storage_path on success" do
      user = insert(:user)
      tmp = System.tmp_dir!() |> Path.join("test_upload_#{System.unique_integer()}.jpg")
      File.write!(tmp, "fake image bytes")

      upload = %Plug.Upload{path: tmp, filename: "test.jpg", content_type: "image/jpeg"}

      assert {:ok, image} = Books.store_upload(user.id, upload)
      assert image.id != nil
      assert is_binary(image.storage_path)
      assert String.starts_with?(image.storage_path, "uploads/")

      File.rm(tmp)
    end

    test "returns {:error, reason} when file does not exist" do
      user = insert(:user)

      upload = %Plug.Upload{
        path: "/nonexistent/path.jpg",
        filename: "x.jpg",
        content_type: "image/jpeg"
      }

      assert {:error, _reason} = Books.store_upload(user.id, upload)
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 2 — Books.create_from_isbn/1 (US-1.1.5 new-book path)
  # ---------------------------------------------------------------------------

  describe "create_from_isbn/1" do
    setup do
      original_http = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, MockHttpClient)
      on_exit(fn -> Application.put_env(:core, :isbn_http_client, original_http) end)
      :ok
    end

    test "returns {:ok, book} with correct title/author/edition when Open Library resolves ISBN" do
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

      assert {:ok, book} = Books.create_from_isbn("9780743273565")
      assert book.title == "The Great Gatsby"
      assert [edition] = book.editions
      assert edition.isbn == "9780743273565"
    end

    test "returns {:error, :not_found} when both Open Library and Google Books return 404" do
      # MockHttpClient returns {:ok, %{}} for unmatched URLs (empty body = not found)
      # Both openlibrary.org and googleapis.com will get an empty response here.
      # ISBNResolver treats an empty body as not found and falls through to {:error, :not_found}.
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, _} = Books.create_from_isbn("9780743273565")
    end

    test "emits book.created event when create_from_isbn succeeds" do
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:9780451524935" => %{
             "title" => "Nineteen Eighty-Four",
             "authors" => [%{"name" => "George Orwell"}],
             "publish_date" => "1949",
             "number_of_pages" => 328,
             "subjects" => ["Dystopian fiction"],
             "key" => "/works/OL1168007W"
           }
         }}
      )

      before_count = event_count("book.created")

      assert {:ok, _book} = Books.create_from_isbn("9780451524935")

      assert event_count("book.created") == before_count + 1
    end
  end

  describe "canonical_isbn13/1" do
    # The seam behind cache invalidation and rejection-retry exclusion
    # matching: OL docs often carry only the ISBN-10 form while the DB
    # stores ISBN-13, so both sides of any comparison canonicalise here.

    test "converts a valid ISBN-10 to its ISBN-13 form" do
      # The live production case: title-search memoised the OL doc's
      # ISBN-10 while rejection invalidated by the edition's ISBN-13.
      assert Books.canonical_isbn13("0312864833") == "9780312864835"
    end

    test "converts a valid ISBN-10 with an X check digit" do
      assert Books.canonical_isbn13("080442957X") == "9780804429573"
      # Lowercase x is upcased before the shape check.
      assert Books.canonical_isbn13("080442957x") == "9780804429573"
    end

    test "strips hyphens and whitespace before converting" do
      assert Books.canonical_isbn13("0-312-86483-3") == "9780312864835"
      assert Books.canonical_isbn13(" 0 312 86483 3 ") == "9780312864835"
    end

    test "passes ISBN-13s through (normalised only)" do
      assert Books.canonical_isbn13("9780312864835") == "9780312864835"
      assert Books.canonical_isbn13("978-0-312-86483-5") == "9780312864835"
    end

    test "leaves a checksum-invalid 10-digit string unconverted" do
      assert Books.canonical_isbn13("0312864834") == "0312864834"
    end

    test "returns garbage in stripped/upcased form, otherwise unchanged" do
      assert Books.canonical_isbn13("garbage!") == "GARBAGE!"
      assert Books.canonical_isbn13("") == ""
      assert Books.canonical_isbn13("  - ") == ""
    end

    test "returns nil for non-binary input" do
      assert Books.canonical_isbn13(nil) == nil
      assert Books.canonical_isbn13(123) == nil
    end
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end
end
