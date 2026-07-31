defmodule Stacks.BooksTest do
  # Coverage note (#345): the three `describe "identify/2"` tests went with
  # `Books.identify/2`, which had no route, worker or context caller — these
  # tests were its only reachability. What they incidentally protected is still
  # covered:
  #
  #   * the steerable `extract_isbn` vision seam — `ai/client_test.exs`,
  #     `ai/mock_client_test.exs`, and end-to-end through the real pipeline in
  #     `upload_pipeline_test.exs` / `upload_telemetry_test.exs` /
  #     `observability_telemetry_test.exs`;
  #   * many-ISBNs-per-image and the per-candidate resolve — `Stacks.Moderation`
  #     (`moderation*_test.exs`) is the production owner of that fan-out, and
  #     `IdentifyBookJob` drives it;
  #   * the `ISBNResolver.resolve/1` miss falling back to the vision result's own
  #     title/author — `isbn_resolver_test.exs`.
  #
  # Nothing must replace them: the only behaviour genuinely lost is that of a
  # function no caller could reach.
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

    # #335 D1. `ISBNResolver.resolve/1` races Open Library and Google Books and
    # returns whichever answered, identified only by which cross-reference id
    # the metadata carries — so that id IS the provenance signal, and these
    # tests pin the mapping rather than the derivation's implementation.
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
      # Moderation's barcode fast path knows something the attrs cannot show:
      # it deliberately skipped the OL/GB round-trip.
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
      # The work already carries its primary edition; this is the second format.
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

    # A work with editions but NO primary flag is drift, not something a write
    # path produces — `create/1` always flags the first edition. It is still a
    # branch `primary_edition/1` deliberately handles (books.ex:124-126), so it
    # is built from `:editionless_book`, the factory's named escape hatch.
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

      # The struct carries only the id, forcing the DB (query) clause.
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

      # Preload order must not sway the pick — both orderings resolve to `older`.
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

    # #291 REGRESSION LOCK: the raw query must reach `plainto_tsquery` so titles
    # with apostrophes/hyphens still match. A prior `String.replace(~r/[^\w\s]/)`
    # sanitiser mangled "O'Brien" → "OBrien" and "spider-man" → "spiderman",
    # changing the lexemes and dropping legitimate matches. Injection-safety comes
    # from Ecto param binding + plainto_tsquery (see search_controller_test.exs
    # "query edge cases"), not from stripping characters.
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

  # #284 — deep search matches book DESCRIPTIONS (not just titles) under
  # `scope: :deep`, ranking title matches ahead of description-only matches and
  # leaving the default (title-only) scope untouched.
  describe "search_books/2 — deep scope (#284)" do
    test "deep scope finds a book matched only by its description" do
      book =
        insert(:book,
          title: "Unrelated Title",
          description: "A sweeping saga of interstellar cartography."
        )

      insert(:book_edition, book: book)

      # Title-only default must MISS it — the term is only in the description.
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

    # Layer 3 DB-assertion punch (mirrors the title_tsv patterns above): prove the
    # two DB mechanisms deep search rests on — the generated description_tsv column
    # and its GIN index — directly, not via search_books/2.
    test "populates the description_tsv tsvector column on book creation" do
      book = insert(:book, description: "Interstellar cartography and star charts.")

      %{rows: [[tsv]]} =
        Repo.query!(
          "SELECT description_tsv::text FROM op.books WHERE id = $1",
          [Ecto.UUID.dump!(book.id)]
        )

      # GENERATED ALWAYS AS to_tsvector('english', coalesce(description,'')) STORED
      # — non-null, stemmed lexemes, `and` dropped as a stopword.
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

  # #296 REGRESSION LOCK: the catalogue search path (`maybe_search/2`, shared by
  # `list_catalogue/1` and `list_for_moderation/1`) uses the SAME `plainto_tsquery`
  # mechanism as `search_books/2` — NOT `ilike` — so there are no `%`/`_` wildcard
  # semantics to worry about; the raw query is passed via the bound param and
  # plainto_tsquery treats it as plain text. A prior `String.replace(~r/[^\w\s]/)`
  # sanitiser was lossy here too ("O'Brien" → "OBrien", "spider-man" → "spiderman"),
  # degrading legitimate catalogue searches. Sibling of #291.
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

    # #355 sibling sweep. The event aggregates the EDITION, and the only
    # subscriber (CacheInvalidationHandler) is keyed by WORK — so without
    # `book_id` in the payload the handler had nothing to evict with, and the
    # test above ("an event was emitted") could not tell. Assert the wire, not
    # the count: the emitted row must name the work whose detail just changed.
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

      # ⚠️ This asserted `book.title != nil` and `book.editions != []` — true of
      # any book at all, so it could not tell the resolver's metadata from a
      # placeholder, nor the requested edition from some other one (Issue #330).
      # The `setup` above registers the exact Open Library payload, so the
      # resolved values are known and can be named.
      assert book.title == "Nineteen Eighty-Four"

      assert [edition] = book.editions
      assert edition.isbn == "9780141036144"
      assert edition.is_primary == true
    end

    test "creates placement on specified shelf when shelf_name provided" do
      user = insert(:user)

      assert {:ok, :created, book} =
               Books.confirm(user.id, %{isbn: "9780141036144", shelf_name: "library"})

      # ⚠️ This asserted only `book.title != nil` — in a test whose whole subject
      # is *which bookshelf the placement lands on*, it never looked at the
      # placement (Issue #330). It would have passed with the book placed on the
      # default wishlist, i.e. with the `shelf_name` argument ignored entirely.
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

    # #333 — inform, never block. Owning the book on ANOTHER bookshelf used to
    # short-circuit to :already_placed, so the requested placement was never
    # made: a silent refusal reported as success. Multi-shelf is legal now, so
    # the placement happens and the caller is handed every shelf to inform with.
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

  # ── #341: one create transaction ──────────────────────────────────────────
  #
  # `Books.create/1` and the private `create_confirmed_book/4` were two
  # independent implementations of "mint a work and its first edition", and they
  # had drifted. Enumerated from both bodies BEFORE the collapse, the
  # `op.book_editions` columns each of them set were:
  #
  #   create/1                 isbn book_id format_label cover_image_url
  #                            page_count publisher publication_year
  #                            open_library_id google_books_id is_primary
  #                            verification_source
  #   create_confirmed_book/4  all of the above EXCEPT google_books_id
  #
  # and on the work row:
  #
  #   create/1                 title author_id description language subjects
  #                            bisac_codes visibility_tier  (whatever the caller
  #                            passed — book_changeset/2's whole cast list)
  #   create_confirmed_book/4  title author_id description subjects
  #                            (the resolver carries no language, bisac_codes or
  #                            visibility_tier, so those were never a drift)
  #
  # The union is asserted below by handing the SAME facts to both entry points
  # and comparing the two rows column by column. Drop a field from the unified
  # `edition_attrs/2` and the comparison goes red.
  describe "create/1 and the confirmed path are one transaction" do
    setup do
      original_http = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, MockHttpClient)
      on_exit(fn -> Application.put_env(:core, :isbn_http_client, original_http) end)
      :ok
    end

    # Deliberately excludes `:isbn` and `:book_id`, which identify the row rather
    # than describe the book: the two paths must be given different ISBNs (the
    # column is unique) and they mint different works.
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

    @tag stories: ["US-1.1.5"]
    test "the confirmed path writes every edition column the direct path writes (Google Books)" do
      confirmed_isbn = "9780451524935"

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})

      MockHttpClient.put_response(
        "googleapis.com",
        {:ok, %{"items" => [google_volume(confirmed_isbn)]}}
      )

      # Confirm FIRST: `confirm/2` refuses to mint a second work whose title and
      # author fuzzy-match one already in the catalogue, and the direct create
      # below is deliberately the same book.
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

      # …and the agreement must not be two all-null rows agreeing about nothing.
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

      # The work row carries the same facts too.
      assert confirmed.title == direct.title
      assert confirmed.description == direct.description
      assert confirmed.subjects == direct.subjects
      refute is_nil(confirmed.author_id)
    end

    @tag stories: ["US-1.1.5"]
    test "the confirmed path writes every edition column the direct path writes (Open Library)" do
      confirmed_isbn = "9780451524935"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok, %{"ISBN:#{confirmed_isbn}" => open_library_book()}}
      )

      # Confirm FIRST — see the Google Books twin above.
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

    # The specific field the drift had already eaten (#341 requirement 2). The
    # cost is not only a missing cross-reference: `verification_source_from/1`
    # reads the identifiers off the row's attrs, so an edition that loses its
    # `google_books_id` also loses its claim to have been verified at all.
    @tag stories: ["US-1.1.5"]
    test "the confirmed path keeps the google_books_id the resolver returned" do
      isbn = "9780451524935"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_volume(isbn)]}})

      user = insert(:user)
      assert {:ok, :created, book} = Books.confirm(user.id, %{isbn: isbn})

      assert hd(book.editions).google_books_id == "gb-gatsby",
             "the resolver returned a Google Books id and the create transaction dropped it"
    end

    # `ISBNResolver.resolve/1` RACES the two sources and returns whichever
    # answered, so each provenance gets its own test with exactly one source
    # able to answer. Registering both and confirming twice in one test makes
    # the second confirm's provenance a coin flip.
    @tag stories: ["US-1.1.5"]
    test "verification_source is google_books when Google Books answered the confirm" do
      isbn = "9780451524935"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_volume(isbn)]}})

      user = insert(:user)
      assert {:ok, :created, book} = Books.confirm(user.id, %{isbn: isbn})
      assert hd(book.editions).verification_source == "google_books"
    end

    @tag stories: ["US-1.1.5"]
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
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])

      assert {:ok, edition} =
               Books.merge_edition(book.id, %{isbn: "9780451524935", format_label: "Hardcover"})

      assert edition.isbn == "9780451524935"
      assert edition.is_primary == false
      assert edition.book_id == book.id
    end

    test "returns {:error, :duplicate_isbn} on duplicate ISBN" do
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])

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
      book = insert(:book, editions: [build(:primary_book_edition, isbn: "9780743273565")])
      before_count = event_count("books.edition_merged")

      Books.merge_edition(book.id, %{isbn: "9780451524935", format_label: "Paperback"})

      assert event_count("books.edition_merged") == before_count + 1
    end

    # #341 requirement 3. `merge_edition/2` resolves the ISBN — an Open Library /
    # Google Books round-trip the platform pays for — and then wrote only the
    # ISBN, the work id, the caller's format label and the provenance, throwing
    # every resolved field away. The merged edition had no cover, no publisher,
    # no page count and no cross-reference id, and nothing downstream could tell
    # "this edition has no publisher" from "nobody ever asked".
    @tag stories: ["US-1.1.8"]
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

    # The stated conflict rule: the caller supplies `isbn` and `format_label`
    # (the endpoint's documented contract) and the resolver fills the rest. A
    # caller-supplied `publisher` is NOT honoured — `BookController.merge_format/2`
    # hands `merge_edition/2` the raw request params, so widening the
    # caller-wins set would turn `POST /api/books/:id/merge-format` into mass
    # assignment over the edition's provenance columns.
    @tag stories: ["US-1.1.8"]
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

      # The resolver's answer for this ISBN, filled in: 328 pages, Open Library key.
      assert edition.page_count == 328
      assert edition.open_library_id == "/works/OL1168007W"
      assert edition.verification_source == "open_library"

      # Open Library carried no publisher and no Google Books id for this ISBN,
      # so both columns stay null — the caller's values did not land.
      assert is_nil(edition.publisher),
             "a caller-supplied publisher reached the row — merge_format/2's raw params are user input"

      assert is_nil(edition.google_books_id),
             "a caller-supplied google_books_id reached the row — that column records provenance"
    end

    @tag stories: ["US-1.1.8"], suite: :events
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
      assert ISBN.canonical_isbn13("0312864833") == "9780312864835"
    end

    test "converts a valid ISBN-10 with an X check digit" do
      assert ISBN.canonical_isbn13("080442957X") == "9780804429573"
      # Lowercase x is upcased before the shape check.
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
