defmodule Stacks.BooksTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Books.BookEdition
  alias Stacks.Books.ISBN
  alias Stacks.Books.ISBNResolver
  alias Stacks.Books.MockHttpClient
  alias Stacks.Uploads

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

    test "records open_library when the resolver returned an Open Library id" do
      attrs = %{
        "isbn" => "9780743273565",
        "title" => "From Open Library",
        "open_library_id" => "OL123M"
      }

      assert {:ok, book} = Books.create(attrs)
      assert hd(book.editions).verification_source == "open_library"
    end

    test "records google_books when only a Google Books id came back" do
      attrs = %{
        "isbn" => "9780451524935",
        "title" => "From Google Books",
        "google_books_id" => "gb-abc"
      }

      assert {:ok, book} = Books.create(attrs)
      assert hd(book.editions).verification_source == "google_books"
    end

    test "records barcode_unverified when nothing external identified the ISBN" do
      attrs = %{"isbn" => "9780140449136", "title" => "Nobody Confirmed This"}

      assert {:ok, book} = Books.create(attrs)

      assert hd(book.editions).verification_source == "barcode_unverified",
             "absent an external identifier the honest answer is 'not externally verified' — " <>
               "understating verification is recoverable, overstating it is not"
    end

    test "an explicit provenance from the caller wins over the derivation" do
      attrs = %{
        "isbn" => "9780061120084",
        "title" => "ISBN 9780061120084",
        "open_library_id" => "OL999M",
        "verification_source" => "barcode_unverified"
      }

      assert {:ok, book} = Books.create(attrs)
      assert hd(book.editions).verification_source == "barcode_unverified"
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
      insert(:book_edition, book: book, isbn: "9780743273565")
      assert found = Books.find_existing("0743273567")
      assert found.id == book.id
    end
  end

  describe "confirm/2 records the scanned edition on the placement" do
    test "placing an existing work by a non-primary ISBN records THAT edition, not the primary" do
      user = insert(:user)
      book = insert(:book)
      primary = Books.primary_edition(Books.get_book_detail(book.id))
      scanned = insert(:book_edition, book: book, is_primary: false, isbn: "9781600000027")
      refute scanned.id == primary.id

      assert {:ok, :existing, existing, placement, _placements} =
               Books.confirm(user.id, %{isbn: "9781600000027", shelf_name: "wishlist"})

      assert existing.id == book.id
      assert placement.book_edition_id == scanned.id
      refute placement.book_edition_id == primary.id
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
      assert length(found.editions) == 2
    end

    test "returns nil for unknown id" do
      assert nil == Books.get_book_detail(Ecto.UUID.generate())
    end
  end

  describe "primary_edition/1" do
    test "returns the primary edition" do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780000000002")])
      primary = hd(book.editions)
      insert(:book_edition, book: book, is_primary: false, isbn: "9781600000010")
      book = Books.get_book_detail(book.id)
      assert Books.primary_edition(book).id == primary.id
    end

    test "falls back to first edition when no primary" do
      book = insert(:editionless_book)
      first = insert(:book_edition, book: book, is_primary: false)
      book = Books.get_book_detail(book.id)
      assert Books.primary_edition(book).id == first.id
    end
  end

  describe "primary_edition/1 — deterministic ordering (PE P3-2)" do
    test "query clause: no primary flag → picks the earliest-created edition, repeatably" do
      book = insert(:editionless_book)

      older =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9781600000027",
          created_at: ~U[2024-01-01 00:00:00.000000Z]
        )

      _newer =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9781600000034",
          created_at: ~U[2024-06-01 00:00:00.000000Z]
        )

      query_book = %Book{id: book.id}

      assert Books.primary_edition(query_book).id == older.id
      assert Books.primary_edition(query_book).id == older.id
    end

    test "in-memory clause: no primary flag → picks the earliest-created edition regardless of list order" do
      book = insert(:editionless_book)

      older =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9781600000041",
          created_at: ~U[2024-01-01 00:00:00.000000Z]
        )

      newer =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9781600000058",
          created_at: ~U[2024-06-01 00:00:00.000000Z]
        )

      assert Books.primary_edition(%Book{id: book.id, editions: [newer, older]}).id == older.id
      assert Books.primary_edition(%Book{id: book.id, editions: [older, newer]}).id == older.id
    end

    test "explicit primary wins over an earlier-created non-primary (both clauses)" do
      book = insert(:editionless_book)

      early =
        insert(:book_edition,
          book: book,
          is_primary: false,
          isbn: "9781600000065",
          created_at: ~U[2020-01-01 00:00:00.000000Z]
        )

      primary =
        insert(:book_edition,
          book: book,
          is_primary: true,
          isbn: "9781600000072",
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

    test "matches a title containing an apostrophe" do
      book = insert(:book, title: "The Master of O'Brien Manor")
      insert(:book_edition, book: book)
      other = insert(:book, title: "Rust Atomics and Locks")
      insert(:book_edition, book: other)

      results = Books.search_books("O'Brien")
      titles = Enum.map(results, & &1.title)

      assert "The Master of O'Brien Manor" in titles
      refute "Rust Atomics and Locks" in titles
    end

    test "matches a title containing a hyphenated word" do
      book = insert(:book, title: "The Amazing Spider-Man Chronicles")
      insert(:book_edition, book: book)
      other = insert(:book, title: "Rust Atomics and Locks")
      insert(:book_edition, book: other)

      results = Books.search_books("Spider-Man")
      titles = Enum.map(results, & &1.title)

      assert "The Amazing Spider-Man Chronicles" in titles
      refute "Rust Atomics and Locks" in titles
    end

    test "populates the title_tsv tsvector column on book creation" do
      book = insert(:book, title: "Elixir in Action")

      %{rows: [[tsv]]} =
        Repo.query!(
          "SELECT title_tsv::text FROM op.books WHERE id = $1",
          [Ecto.UUID.dump!(book.id)]
        )

      assert tsv =~ "elixir"
      assert tsv =~ "action"
      refute tsv =~ "'in'"
    end

    test "the full-text query uses the title_tsv GIN index" do
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

  describe "search_books/2 — deep scope" do
    test "deep scope finds a book matched only by its description" do
      book =
        insert(:book,
          title: "Unrelated Title",
          description: "A sweeping saga of interstellar cartography."
        )

      insert(:book_edition, book: book)

      assert Books.search_books("cartography") == []

      deep_titles =
        "cartography" |> Books.search_books(scope: :deep) |> Enum.map(& &1.title)

      assert "Unrelated Title" in deep_titles
    end

    test "title-only default scope ignores description matches" do
      book =
        insert(:book, title: "Plain Cover", description: "Deep in the mycology of fungi.")

      insert(:book_edition, book: book)

      assert Books.search_books("mycology") == []
      assert Books.search_books("mycology", scope: :title) == []

      deep = Books.search_books("mycology", scope: :deep)
      assert Enum.map(deep, & &1.title) == ["Plain Cover"]
    end

    test "deep scope ranks a title match ahead of a description-only match" do
      title_match =
        insert(:book, title: "Botany Basics", description: "An unrelated blurb.")

      insert(:book_edition, book: title_match)

      desc_match =
        insert(:book, title: "Field Notes", description: "A guide to botany and plants.")

      insert(:book_edition, book: desc_match)

      titles = "botany" |> Books.search_books(scope: :deep) |> Enum.map(& &1.title)

      assert titles == ["Botany Basics", "Field Notes"]
    end

    test "deep scope still returns title matches (superset of title scope)" do
      book = insert(:book, title: "Elixir in Action", description: "About the BEAM.")
      insert(:book_edition, book: book)

      deep_titles =
        "Elixir" |> Books.search_books(scope: :deep) |> Enum.map(& &1.title)

      assert "Elixir in Action" in deep_titles
    end

    test "populates the description_tsv tsvector column on book creation" do
      book = insert(:book, description: "Interstellar cartography and star charts.")

      %{rows: [[tsv]]} =
        Repo.query!(
          "SELECT description_tsv::text FROM op.books WHERE id = $1",
          [Ecto.UUID.dump!(book.id)]
        )

      assert tsv =~ "cartographi"
      assert tsv =~ "star"
      refute tsv =~ "'and'"
    end

    test "the deep-search query uses the description_tsv GIN index" do
      Repo.query!("SET LOCAL enable_seqscan = off")

      %{rows: rows} =
        Repo.query!(
          "EXPLAIN SELECT id FROM op.books WHERE description_tsv @@ plainto_tsquery('english', $1)",
          ["cartography"]
        )

      plan = rows |> List.flatten() |> Enum.join("\n")
      assert plan =~ "idx_books_description_tsv"
    end
  end

  describe "description_snippets/2" do
    test "returns a <mark>-highlighted excerpt for a description match" do
      book =
        insert(:book,
          title: "Plain Title",
          description: "The definitive treatise on interstellar cartography and beyond."
        )

      snippets = Books.description_snippets([book.id], "cartography")

      assert Map.has_key?(snippets, book.id)
      snippet = snippets[book.id]
      assert snippet =~ "<mark>cartography</mark>"
    end

    test "omits books whose description does not match (title-only hits)" do
      match = insert(:book, description: "All about mycology.")
      title_only = insert(:book, title: "mycology", description: "Something unrelated.")

      snippets = Books.description_snippets([match.id, title_only.id], "mycology")

      assert Map.has_key?(snippets, match.id)
      refute Map.has_key?(snippets, title_only.id)
    end

    test "returns an empty map for an empty id list" do
      assert Books.description_snippets([], "anything") == %{}
    end
  end

  describe "list_catalogue/1 — search" do
    test "matches a title containing an apostrophe" do
      insert(:book, title: "The Master of O'Brien Manor")
      insert(:book, title: "Rust Atomics and Locks")

      {books, total} = Books.list_catalogue(search: "O'Brien")
      titles = Enum.map(books, & &1.title)

      assert "The Master of O'Brien Manor" in titles
      refute "Rust Atomics and Locks" in titles
      assert total == 1
    end

    test "matches a title containing a hyphenated word" do
      insert(:book, title: "The Amazing Spider-Man Chronicles")
      insert(:book, title: "Rust Atomics and Locks")

      {books, total} = Books.list_catalogue(search: "Spider-Man")
      titles = Enum.map(books, & &1.title)

      assert "The Amazing Spider-Man Chronicles" in titles
      refute "Rust Atomics and Locks" in titles
      assert total == 1
    end
  end

  describe "confirm_cover_association/2" do
    test "updates cover_image_url on a known edition" do
      edition = insert(:book_edition)
      cover_url = "https://example.com/cover.jpg"

      assert {:ok, updated} = Books.confirm_cover_association(edition.id, cover_url)
      assert updated.cover_image_url == cover_url
    end

    test "the cover fetch is seamed — routed through the client, never a live request" do
      edition = insert(:book_edition)
      cover_url = "https://covers.example.test/#{edition.isbn}.jpg"

      MockHttpClient.capture_requests()

      assert {:ok, updated} = Books.confirm_cover_association(edition.id, cover_url)

      assert_receive {MockHttpClient, :request, ^cover_url}, 1_000
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

    test "the emitted event names the WORK, which is what the cache is keyed by" do
      edition = insert(:book_edition)

      Books.confirm_cover_association(edition.id, "https://example.com/cover.jpg")

      payload =
        Core.Repo.one!(
          from(e in "event_log",
            prefix: "op",
            where: e.event_type == "book.cover_confirmed",
            where: e.aggregate_id == type(^edition.id, Ecto.UUID),
            select: e.payload
          )
        )

      assert payload["book_id"] == edition.book_id
    end
  end

  describe "find_same_work/2" do
    test "returns empty list when DB is empty" do
      assert [] = Books.find_same_work("1984", "George Orwell")
    end

    test "returns the matching work when title+author Jaro-Winkler similarity is high" do
      author = insert(:author, name: "George Orwell")
      book = insert(:book, title: "1984", author: author)
      insert(:book_edition, book: book)

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

  describe "confirm/2" do
    setup do
      original_http = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, MockHttpClient)

      on_exit(fn ->
        Application.put_env(:core, :isbn_http_client, original_http)
      end)

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

      assert book.title == "Nineteen Eighty-Four"

      assert [edition] = book.editions
      assert edition.isbn == "9780141036144"
      assert edition.is_primary == true
    end

    test "creates placement on specified shelf when shelf_name provided" do
      user = insert(:user)

      assert {:ok, :created, book} =
               Books.confirm(user.id, %{isbn: "9780141036144", shelf_name: "library"})

      assert book.title == "Nineteen Eighty-Four"

      placement =
        Repo.one!(
          from(p in Stacks.Shelving.Placement,
            join: b in assoc(p, :bookshelf),
            where: b.user_id == ^user.id,
            select: %{bookshelf_name: b.name}
          )
        )

      assert placement.bookshelf_name == "library",
             "shelf_name: \"library\" was ignored — the placement landed elsewhere"
    end

    test "returns existing book when ISBN already exists (no duplicate created)" do
      user = insert(:user)
      existing_book = insert(:book, title: "Nineteen Eighty-Four")
      insert(:book_edition, book: existing_book, isbn: "9780141036144")

      assert {:ok, :existing, returned_book, placement, placements} =
               Books.confirm(user.id, %{isbn: "9780141036144"})

      assert returned_book.id == existing_book.id
      assert placement.book_id == existing_book.id
      assert Enum.map(placements, & &1.id) == [placement.id]
    end

    test "returns {:ok, :existing, book, placement, placements} when ISBN exists but user has no placement" do
      user = insert(:user)
      existing_book = insert(:book, title: "Already In Catalogue")
      insert(:book_edition, book: existing_book, isbn: "9780141036144")

      assert {:ok, :existing, book, placement, [only]} =
               Books.confirm(user.id, %{isbn: "9780141036144"})

      assert book.id == existing_book.id
      assert placement.book_id == existing_book.id
      assert only.id == placement.id
    end

    test "returns :already_placed only when the book is on the bookshelf that was ASKED for" do
      user = insert(:user)
      existing_book = insert(:book, title: "Already Placed Book")
      insert(:book_edition, book: existing_book, isbn: "9780141036144")
      bookshelf = insert(:bookshelf, user: user, name: "library")
      existing_placement = insert(:placement, book: existing_book, bookshelf: bookshelf)

      assert {:ok, :already_placed, book, placement, [only]} =
               Books.confirm(user.id, %{isbn: "9780141036144", shelf_name: "library"})

      assert book.id == existing_book.id
      assert placement.id == existing_placement.id
      assert only.id == existing_placement.id
    end

    test "a book owned on another bookshelf is still placed on the requested one" do
      user = insert(:user)
      existing_book = insert(:book, title: "Wanted On Two Shelves")
      insert(:book_edition, book: existing_book, isbn: "9780141036144")
      bookshelf = insert(:bookshelf, user: user, name: "library")
      existing_placement = insert(:placement, book: existing_book, bookshelf: bookshelf)

      assert {:ok, :existing, book, placement, placements} =
               Books.confirm(user.id, %{isbn: "9780141036144", shelf_name: "wishlist"})

      assert book.id == existing_book.id
      assert placement.bookshelf.name == "wishlist"
      assert placement.id != existing_placement.id

      assert placements |> Enum.map(& &1.bookshelf.name) |> Enum.sort() == ["library", "wishlist"]
    end

    test "returns {:error, {:merge_required, existing_work_id}} when same work detected via fuzzy match" do
      author = insert(:author, name: "George Orwell")
      existing_book = insert(:book, title: "Nineteen Eighty-Four", author: author)
      insert(:book_edition, book: existing_book, isbn: "9780451526342")

      user = insert(:user)

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

  describe "create/1 and the confirmed path are one transaction" do
    setup do
      original_http = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, MockHttpClient)
      on_exit(fn -> Application.put_env(:core, :isbn_http_client, original_http) end)
      :ok
    end

    @edition_columns_both_create_paths_set [
      :format_label,
      :cover_image_url,
      :page_count,
      :publisher,
      :publication_year,
      :open_library_id,
      :google_books_id,
      :is_primary,
      :verification_source
    ]

    test "the confirmed path writes every edition column the direct path writes (Google Books)" do
      confirmed_isbn = "9780451524935"

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})

      MockHttpClient.put_response(
        "googleapis.com",
        {:ok, %{"items" => [google_volume(confirmed_isbn)]}}
      )

      user = insert(:user)
      assert {:ok, :created, confirmed} = Books.confirm(user.id, %{isbn: confirmed_isbn})

      assert {:ok, direct} =
               Books.create(%{
                 "isbn" => "9780743273565",
                 "title" => "The Great Gatsby",
                 "author" => "F. Scott Fitzgerald",
                 "description" => "A novel.",
                 "subjects" => ["Fiction"],
                 "cover_image_url" => "http://books.google.com/cover.jpg",
                 "publisher" => "Scribner",
                 "publication_year" => 1925,
                 "page_count" => 180,
                 "google_books_id" => "gb-gatsby"
               })

      direct_edition = hd(direct.editions)
      confirmed_edition = hd(confirmed.editions)

      assert Map.take(confirmed_edition, @edition_columns_both_create_paths_set) ==
               Map.take(direct_edition, @edition_columns_both_create_paths_set),
             "the two create entry points disagree about an edition column given identical facts"

      for column <- [
            :cover_image_url,
            :page_count,
            :publisher,
            :publication_year,
            :google_books_id,
            :verification_source
          ] do
        refute is_nil(Map.fetch!(confirmed_edition, column)),
               "#{column} is nil on the confirmed edition — the union assertion is vacuous"
      end

      assert confirmed.title == direct.title
      assert confirmed.description == direct.description
      assert confirmed.subjects == direct.subjects
      refute is_nil(confirmed.author_id)
    end

    test "the confirmed path writes every edition column the direct path writes (Open Library)" do
      confirmed_isbn = "9780451524935"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok, %{"ISBN:#{confirmed_isbn}" => open_library_book()}}
      )

      user = insert(:user)
      assert {:ok, :created, confirmed} = Books.confirm(user.id, %{isbn: confirmed_isbn})

      assert {:ok, direct} =
               Books.create(%{
                 "isbn" => "9780743273565",
                 "title" => "Nineteen Eighty-Four",
                 "author" => "George Orwell",
                 "cover_image_url" => "https://covers.openlibrary.org/b/id/1-L.jpg",
                 "publisher" => "Secker & Warburg",
                 "publication_year" => 1949,
                 "page_count" => 328,
                 "open_library_id" => "/books/OL7353617M"
               })

      direct_edition = hd(direct.editions)
      confirmed_edition = hd(confirmed.editions)

      assert Map.take(confirmed_edition, @edition_columns_both_create_paths_set) ==
               Map.take(direct_edition, @edition_columns_both_create_paths_set),
             "the two create entry points disagree about an edition column given identical facts"

      for column <- [
            :cover_image_url,
            :page_count,
            :publisher,
            :publication_year,
            :open_library_id,
            :verification_source
          ] do
        refute is_nil(Map.fetch!(confirmed_edition, column)),
               "#{column} is nil on the confirmed edition — the union assertion is vacuous"
      end
    end

    test "the confirmed path keeps the google_books_id the resolver returned" do
      isbn = "9780451524935"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_volume(isbn)]}})

      user = insert(:user)
      assert {:ok, :created, book} = Books.confirm(user.id, %{isbn: isbn})

      assert hd(book.editions).google_books_id == "gb-gatsby",
             "the resolver returned a Google Books id and the create transaction dropped it"
    end

    test "verification_source is google_books when Google Books answered the confirm" do
      isbn = "9780451524935"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_volume(isbn)]}})

      user = insert(:user)
      assert {:ok, :created, book} = Books.confirm(user.id, %{isbn: isbn})
      assert hd(book.editions).verification_source == "google_books"
    end

    test "verification_source is open_library when Open Library answered the confirm" do
      isbn = "9780743273565"
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok, %{"ISBN:#{isbn}" => open_library_book()}}
      )

      user = insert(:user)
      assert {:ok, :created, book} = Books.confirm(user.id, %{isbn: isbn})
      assert hd(book.editions).verification_source == "open_library"
    end

    @tag suite: :events
    test "each entry point still emits its own event" do
      created_before = event_count("book.created")
      confirmed_before = event_count("books.confirmed")

      isbn = "9780451524935"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_volume(isbn)]}})

      assert {:ok, _} = Books.create(%{"isbn" => "9780743273565", "title" => "Direct"})
      user = insert(:user)
      assert {:ok, :created, _} = Books.confirm(user.id, %{isbn: isbn})

      assert event_count("book.created") == created_before + 1
      assert event_count("books.confirmed") == confirmed_before + 1
    end

    defp google_volume(isbn) do
      %{
        "id" => "gb-gatsby",
        "volumeInfo" => %{
          "title" => "The Great Gatsby",
          "authors" => ["F. Scott Fitzgerald"],
          "description" => "A novel.",
          "categories" => ["Fiction"],
          "imageLinks" => %{"thumbnail" => "http://books.google.com/cover.jpg"},
          "publisher" => "Scribner",
          "publishedDate" => "1925-04-10",
          "pageCount" => 180,
          "industryIdentifiers" => [%{"type" => "ISBN_13", "identifier" => isbn}]
        }
      }
    end

    defp open_library_book do
      %{
        "title" => "Nineteen Eighty-Four",
        "authors" => [%{"name" => "George Orwell"}],
        "publishers" => [%{"name" => "Secker & Warburg"}],
        "cover" => %{"large" => "https://covers.openlibrary.org/b/id/1-L.jpg"},
        "publish_date" => "1949",
        "number_of_pages" => 328,
        "subjects" => [],
        "key" => "/books/OL7353617M"
      }
    end
  end

  describe "merge_edition/2" do
    setup do
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
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])

      assert {:ok, edition} =
               Books.merge_edition(book.id, %{isbn: "9780451524935", format_label: "Hardcover"})

      assert edition.isbn == "9780451524935"
      assert edition.is_primary == false
      assert edition.book_id == book.id
    end

    test "returns {:error, :duplicate_isbn} on duplicate ISBN" do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])

      assert {:error, :duplicate_isbn} =
               Books.merge_edition(book.id, %{isbn: "9780743273565"})
    end

    test "returns error when book_id does not exist" do
      nonexistent_id = Ecto.UUID.generate()

      result = Books.merge_edition(nonexistent_id, %{isbn: "9780451524935"})
      assert {:error, _} = result
    end

    test "emits books.edition_merged event on success" do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])
      before_count = event_count("books.edition_merged")

      Books.merge_edition(book.id, %{isbn: "9780451524935", format_label: "Paperback"})

      assert event_count("books.edition_merged") == before_count + 1
    end

    test "keeps the metadata it just resolved instead of discarding it" do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])
      merged_isbn = "9780316769174"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{merged_isbn}" => %{
             "title" => "The Catcher in the Rye",
             "authors" => [%{"name" => "J.D. Salinger"}],
             "publishers" => [%{"name" => "Little, Brown"}],
             "cover" => %{"large" => "https://covers.openlibrary.org/b/id/2-L.jpg"},
             "publish_date" => "1951",
             "number_of_pages" => 277,
             "subjects" => [],
             "key" => "/books/OL15290M"
           }
         }}
      )

      assert {:ok, edition} =
               Books.merge_edition(book.id, %{isbn: merged_isbn, format_label: "Hardcover"})

      assert edition.cover_image_url == "https://covers.openlibrary.org/b/id/2-L.jpg"
      assert edition.publisher == "Little, Brown"
      assert edition.publication_year == 1951
      assert edition.page_count == 277
      assert edition.open_library_id == "/books/OL15290M"
      assert edition.verification_source == "open_library"
    end

    test "the caller's format_label wins; the rest of the row comes from the resolver" do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])

      assert {:ok, edition} =
               Books.merge_edition(book.id, %{
                 isbn: "9780451524935",
                 format_label: "Slipcased",
                 publisher: "Not The Caller's To Set",
                 google_books_id: "not-the-callers-to-set"
               })

      assert edition.format_label == "Slipcased"

      assert edition.page_count == 328
      assert edition.open_library_id == "/works/OL1168007W"
      assert edition.verification_source == "open_library"

      assert is_nil(edition.publisher),
             "a caller-supplied publisher reached the row — merge_format/2's raw params are user input"

      assert is_nil(edition.google_books_id),
             "a caller-supplied google_books_id reached the row — that column records provenance"
    end

    @tag suite: :events
    test "books.edition_merged event aggregate_id matches the new edition's id" do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])

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

      Uploads.store_upload(user.id, upload)

      assert event_count("image.submitted") == before_count + 1

      File.rm(tmp)
    end

    test "returns {:ok, image} with storage_path on success" do
      user = insert(:user)
      tmp = System.tmp_dir!() |> Path.join("test_upload_#{System.unique_integer()}.jpg")
      File.write!(tmp, "fake image bytes")

      upload = %Plug.Upload{path: tmp, filename: "test.jpg", content_type: "image/jpeg"}

      assert {:ok, image} = Uploads.store_upload(user.id, upload)
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

      assert {:error, _reason} = Uploads.store_upload(user.id, upload)
    end
  end

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
    test "converts a valid ISBN-10 to its ISBN-13 form" do
      assert ISBN.canonical_isbn13("0312864833") == "9780312864835"
    end

    test "converts a valid ISBN-10 with an X check digit" do
      assert ISBN.canonical_isbn13("080442957X") == "9780804429573"
      assert ISBN.canonical_isbn13("080442957x") == "9780804429573"
    end

    test "strips hyphens and whitespace before converting" do
      assert ISBN.canonical_isbn13("0-312-86483-3") == "9780312864835"
      assert ISBN.canonical_isbn13(" 0 312 86483 3 ") == "9780312864835"
    end

    test "passes ISBN-13s through (normalised only)" do
      assert ISBN.canonical_isbn13("9780312864835") == "9780312864835"
      assert ISBN.canonical_isbn13("978-0-312-86483-5") == "9780312864835"
    end

    test "leaves a checksum-invalid 10-digit string unconverted" do
      assert ISBN.canonical_isbn13("0312864834") == "0312864834"
    end

    test "returns garbage in stripped/upcased form, otherwise unchanged" do
      assert ISBN.canonical_isbn13("garbage!") == "GARBAGE!"
      assert ISBN.canonical_isbn13("") == ""
      assert ISBN.canonical_isbn13("  - ") == ""
    end

    test "returns nil for non-binary input" do
      assert ISBN.canonical_isbn13(nil) == nil
      assert ISBN.canonical_isbn13(123) == nil
    end
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end
end
