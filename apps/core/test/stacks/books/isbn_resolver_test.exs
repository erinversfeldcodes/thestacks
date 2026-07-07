defmodule Stacks.Books.ISBNResolverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Stacks.Books.{ISBNResolver, MockHttpClient}

  # ---------------------------------------------------------------------------
  # Fixture helpers
  # ---------------------------------------------------------------------------

  defp ol_book_data(opts \\ []) do
    %{
      "title" => opts[:title] || "The Great Gatsby",
      "authors" => [%{"name" => opts[:author] || "F. Scott Fitzgerald"}],
      "publish_date" => opts[:publish_date] || "1925",
      "number_of_pages" => opts[:pages] || 180,
      "subjects" => opts[:subjects] || ["American fiction", %{"name" => "Jazz Age"}],
      "key" => "/books/OL7353617M"
    }
  end

  defp google_item(opts \\ []) do
    %{
      "id" => "abc123",
      "volumeInfo" => %{
        "title" => opts[:title] || "The Great Gatsby",
        "authors" => [opts[:author] || "F. Scott Fitzgerald"],
        "publishedDate" => opts[:published_date] || "1925-04-10",
        "pageCount" => opts[:pages] || 180,
        "description" => opts[:description] || "A novel.",
        "categories" => opts[:categories] || ["Fiction"],
        "publisher" => opts[:publisher] || "Scribner",
        "imageLinks" => %{"thumbnail" => "http://books.google.com/cover.jpg"},
        "industryIdentifiers" =>
          opts[:identifiers] ||
            [
              %{"type" => "ISBN_13", "identifier" => "9780743273565"},
              %{"type" => "ISBN_10", "identifier" => "0743273567"}
            ]
      }
    }
  end

  defp ol_search_doc(opts \\ []) do
    doc = %{
      "isbn" => opts[:isbn] || ["9780743273565"],
      "title" => opts[:title] || "The Great Gatsby",
      "author_name" => opts[:author_name] || ["F. Scott Fitzgerald"],
      "subject" => opts[:subject] || ["American fiction"],
      "first_publish_year" => opts[:year] || 1925
    }

    # OL omits the `subtitle` key entirely for most docs — only add it
    # when the fixture asks for one, mirroring the real response shape.
    case opts[:subtitle] do
      nil -> doc
      subtitle -> Map.put(doc, "subtitle", subtitle)
    end
  end

  # REAL OL response for the "Train to Crystal City" production
  # failure (query title="The Crystal City", verified against the live
  # API 2026-06-10). OL returns subtitle: nil for EVERY doc — the
  # Russell book is disambiguated by its subjects, not a subtitle. OL
  # ranks Orson Scott Card's fantasy novel first (exact-prefix match on
  # the VLM's enriched title), with the correct Jan Jarboe Russell book
  # as doc #3. Take-first returned Card; scoring must return Russell.
  defp crystal_city_docs do
    [
      ol_search_doc(
        title: "The Crystal City",
        author_name: ["Orson Scott Card"],
        isbn: ["9781429964500"],
        subject: [
          "Alvin Maker (Fictitious character)",
          "Fiction",
          "Magic",
          "Frontier and pioneer life",
          "Fiction, fantasy, general",
          "Alvin Maker"
        ]
      ),
      ol_search_doc(
        title: "The Crystal City",
        author_name: ["Janice Tarantino"],
        isbn: ["9780505521453"],
        subject: []
      ),
      ol_search_doc(
        title: "The train to Crystal City",
        author_name: ["Jan Jarboe Russell"],
        isbn: ["9781451693669"],
        subject: [
          "Concentration camps",
          "German Americans",
          "World War, 1939-1945",
          "Crystal City Internment Camp (Crystal City, Tex.)",
          "Evacuation of civilians",
          "Forced repatriation"
        ],
        year: 2015
      ),
      # No ISBN — excluded before scoring.
      ol_search_doc(
        title: "The crystal city",
        author_name: ["Paschal] [Grousset"],
        isbn: []
      ),
      ol_search_doc(
        title: "The crystal city",
        author_name: ["Nancy Etchemendy"],
        isbn: ["9780590354653"],
        subject: ["Science fiction", "Children's fiction"]
      )
    ]
  end

  # Drain the URLs captured via `MockHttpClient.capture_requests/0`.
  # All resolver Tasks have completed by the time search_by_title
  # returns, so the messages are already in the mailbox.
  defp collect_request_urls(acc \\ []) do
    receive do
      {MockHttpClient, :request, url} -> collect_request_urls([url | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The resolver's decision diagnostics are Logger.info, but test.exs
  # pins the primary Logger level at :warning and capture_log's :level
  # option does NOT raise the primary level — info events would never
  # reach the capture handler. Temporarily raise the primary level for
  # the duration of the capture. Concurrent async tests may log more
  # verbosely during the window, which is harmless (no other test
  # asserts on captured logs).
  defp capture_resolver_log(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  # ---------------------------------------------------------------------------
  # resolve/1 — Open Library
  # ---------------------------------------------------------------------------

  describe "resolve/1 — Open Library" do
    test "returns {:ok, metadata} when Open Library has the ISBN" do
      isbn = "9780743273565"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok, %{"ISBN:#{isbn}" => ol_book_data()}}
      )

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.title == "The Great Gatsby"
      assert meta.author == "F. Scott Fitzgerald"
      assert meta.publication_year == 1925
      assert meta.source == :open_library
    end

    test "extracts page count and open_library_id" do
      isbn = "9780743273565"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok, %{"ISBN:#{isbn}" => ol_book_data(pages: 200)}}
      )

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.page_count == 200
      assert meta.open_library_id == "/books/OL7353617M"
    end

    test "extracts binary subjects" do
      isbn = "9780743273565"

      data =
        ol_book_data(subjects: ["American fiction", "Classic literature"])

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{"ISBN:#{isbn}" => data}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert "American fiction" in meta.subjects
    end

    test "extracts map subjects via name key" do
      isbn = "9780743273565"

      data =
        ol_book_data(subjects: [%{"name" => "Jazz Age"}, %{"name" => "New York"}])

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{"ISBN:#{isbn}" => data}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert "Jazz Age" in meta.subjects
    end

    test "ignores subject entries with unknown format" do
      isbn = "9780743273565"
      data = ol_book_data(subjects: [42, nil, "valid"])
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{"ISBN:#{isbn}" => data}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.subjects == ["valid"]
    end

    test "returns {:error, :not_found} when ISBN key not in body" do
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok, %{"ISBN:0000000000000" => ol_book_data()}}
      )

      assert {:error, :not_found} = ISBNResolver.resolve("9780743273565")
    end

    test "returns {:error, :not_found} when body is empty map" do
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} = ISBNResolver.resolve("9780743273565")
    end

    test "parse_year handles nil publish_date" do
      isbn = "9780743273565"
      data = Map.put(ol_book_data(), "publish_date", nil)
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{"ISBN:#{isbn}" => data}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.publication_year == nil
    end

    test "parse_year handles non-numeric date string" do
      isbn = "9780743273565"
      data = Map.put(ol_book_data(), "publish_date", "Unknown")
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{"ISBN:#{isbn}" => data}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.publication_year == nil
    end
  end

  # ---------------------------------------------------------------------------
  # resolve/1 — fallback to Google Books
  # ---------------------------------------------------------------------------

  describe "resolve/1 — Google Books fallback" do
    test "falls back to Google Books when Open Library returns empty" do
      isbn = "9780743273565"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_item()]}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.title == "The Great Gatsby"
      assert meta.source == :google_books
    end

    test "falls back to Google Books when Open Library HTTP request fails" do
      isbn = "9780743273565"
      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :timeout})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_item()]}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.source == :google_books
    end

    test "Google Books returns ISBN_10 when no ISBN_13" do
      isbn = "0743273567"

      item =
        google_item(identifiers: [%{"type" => "ISBN_10", "identifier" => "0743273567"}])

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [item]}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.source == :google_books
    end

    test "resolve succeeds even when response has no industryIdentifiers (ISBN already known)" do
      isbn = "9780743273565"
      item = google_item(identifiers: [])
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [item]}})

      # parse_google_books does not re-extract ISBN — resolve already knows it
      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.source == :google_books
    end

    test "returns {:error, :not_found} when Google Books returns no items" do
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"totalItems" => 0}})

      assert {:error, :not_found} = ISBNResolver.resolve("9780743273565")
    end

    test "Google Books extracts cover_image_url, publisher, google_books_id" do
      isbn = "9780743273565"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_item()]}})

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.cover_image_url == "http://books.google.com/cover.jpg"
      assert meta.publisher == "Scribner"
      assert meta.google_books_id == "abc123"
    end

    test "parse_year handles full ISO date from Google Books" do
      isbn = "9780743273565"
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})

      MockHttpClient.put_response(
        "googleapis.com",
        {:ok, %{"items" => [google_item(published_date: "2004-09-30")]}}
      )

      assert {:ok, meta} = ISBNResolver.resolve(isbn)
      assert meta.publication_year == 2004
    end
  end

  # ---------------------------------------------------------------------------
  # search_by_title/3 — Open Library title search
  # ---------------------------------------------------------------------------

  describe "search_by_title/3 — Open Library" do
    test "returns {:ok, isbn, metadata} when OL search finds a match" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, isbn, meta} = ISBNResolver.search_by_title("The Great Gatsby", "Fitzgerald")
      assert isbn == "9780743273565"
      assert meta.source == :open_library
    end

    test "prefers ISBN-13 over ISBN-10 in search results" do
      doc = ol_search_doc(isbn: ["0743273567", "9780743273565"])
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => [doc]}})

      assert {:ok, "9780743273565", _meta} = ISBNResolver.search_by_title("Gatsby")
    end

    test "uses ISBN-10 when no ISBN-13 available" do
      doc = ol_search_doc(isbn: ["0743273567"])
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => [doc]}})

      assert {:ok, "0743273567", _meta} = ISBNResolver.search_by_title("Gatsby")
    end

    test "skips docs without any ISBN" do
      no_isbn = Map.delete(ol_search_doc(), "isbn")
      with_isbn = ol_search_doc(isbn: ["9780743273565"])

      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [no_isbn, with_isbn]}}
      )

      assert {:ok, "9780743273565", _meta} = ISBNResolver.search_by_title("Gatsby")
    end

    test "returns nil author when author_name is empty" do
      doc = Map.put(ol_search_doc(), "author_name", [])
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => [doc]}})

      assert {:ok, _, meta} = ISBNResolver.search_by_title("Gatsby")
      assert meta.author == nil
    end

    test "returns {:error, :not_found} when docs list is empty" do
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} = ISBNResolver.search_by_title("ZZZNoMatch")
    end
  end

  # ---------------------------------------------------------------------------
  # search_by_title/3 — Google Books title search fallback
  # ---------------------------------------------------------------------------

  describe "search_by_title/3 — Google Books fallback" do
    test "falls back to Google Books when OL search fails" do
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [google_item()]}})

      assert {:ok, "9780743273565", meta} =
               ISBNResolver.search_by_title("The Great Gatsby", "Fitzgerald")

      assert meta.source == :google_books
    end

    test "returns {:error, :not_found} when both OL and GB fail" do
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} = ISBNResolver.search_by_title("ZZZNoMatch")
    end

    test "returns {:error, :not_found} when Google Books item has no industryIdentifiers" do
      item = google_item(identifiers: [])
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [item]}})

      assert {:error, :not_found} = ISBNResolver.search_by_title("Gatsby")
    end
  end

  # ---------------------------------------------------------------------------
  # search_by_title/3 — candidate generation
  # ---------------------------------------------------------------------------

  describe "search_by_title/3 — candidate generation" do
    test "with nil author still searches" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, _, _} = ISBNResolver.search_by_title("The Great Gatsby", nil)
    end

    test "strips subtitle from title for additional candidates" do
      # "Born Again Bodies: A Novel" → also tries "Born Again Bodies"
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, _, _} =
               ISBNResolver.search_by_title("The Great Gatsby: A Novel", "Fitzgerald")
    end

    test "with single-word title does not generate trimmed candidates" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, _, _} = ISBNResolver.search_by_title("Gatsby")
    end

    test "with raw_text generates enriched candidates first" do
      # raw_text triggers the enriched_prefix path. The doc must actually
      # match the signals now that single candidates are scored against
      # the plausibility floor — a non-matching doc is correctly floored.
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc(title: "The Crystal City")]}}
      )

      assert {:ok, _, _} =
               ISBNResolver.search_by_title(
                 "The Crystal C",
                 "Johnson",
                 "F D R train crystal city 1942"
               )
    end

    test "with nil raw_text skips enriched prefix" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, _, _} = ISBNResolver.search_by_title("Gatsby", "Fitzgerald", nil)
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_raw_text (exercised via search_by_title raw_text param)
  # ---------------------------------------------------------------------------

  describe "normalize_raw_text via search_by_title" do
    test "joins space-separated acronym letters like F D R → fdr" do
      # Fail the plain-title candidates (empty docs) so the enriched
      # variants fire, then assert the raw_text keywords went out on the
      # wire as the joined "fdr" token.
      MockHttpClient.capture_requests()
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      MockHttpClient.put_response(
        "fdr",
        {:ok, %{"docs" => [ol_search_doc(title: "Train to Crystal City")]}}
      )

      assert {:ok, _, _} = ISBNResolver.search_by_title("Train to Crystal City", nil, "F D R")

      urls = collect_request_urls()
      assert Enum.any?(urls, &String.contains?(&1, "fdr"))
    end

    test "possessive apostrophes never produce orphan-letter gluing (scrystal bug)" do
      # Production regression: raw_text "THE TRAMP'S CRYSTAL CITY" used
      # to normalise to "tramp scrystal city" — the apostrophe became a
      # space and the orphan "s" was glued onto the NEXT word, poisoning
      # every enriched query variant. It must normalise to
      # "tramps crystal city" instead.
      MockHttpClient.capture_requests()
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} =
               ISBNResolver.search_by_title(
                 "The Tramp's Crystal City",
                 nil,
                 "THE TRAMP'S CRYSTAL CITY"
               )

      urls = collect_request_urls()
      enriched = Enum.filter(urls, &String.contains?(&1, "tramps"))

      assert enriched != [], "expected enriched queries containing the 'tramps' keyword"
      refute Enum.any?(urls, &String.contains?(&1, "scrystal"))
    end

    test "empty string raw_text skips enriched prefix" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc(title: "Gatsby")]}}
      )

      assert {:ok, _, _} = ISBNResolver.search_by_title("Gatsby", nil, "")
    end
  end

  # ---------------------------------------------------------------------------
  # search_by_title/4 — candidate scoring (score-everything-pick-best)
  # ---------------------------------------------------------------------------

  describe "search_by_title/4 — candidate scoring" do
    test "picks the best-scoring doc, not the first, when OL ranks the wrong book on top" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => crystal_city_docs()}}
      )

      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:ok, "9781451693669", meta} =
               ISBNResolver.search_by_title(
                 "The Crystal City: The Tragedy of America's First Internment Camp",
                 "Doris Akers",
                 "THE CRYSTAL CI IT IS ABOUT F DRS"
               )

      assert meta.title == "The train to Crystal City"
      # Real OL search docs carry no subtitle — disambiguation comes
      # from the subjects list (resolver passes the first 5 through).
      assert meta.subtitle == nil
      assert meta.author == "Jan Jarboe Russell"
      assert "Crystal City Internment Camp (Crystal City, Tex.)" in meta.subjects
    end

    test "scoring composes with exclusion: excluded docs are not scored" do
      # Exclude the Russell ISBN — the best-scoring doc — and the
      # resolver must fall back to the best of the remaining docs
      # rather than returning the excluded one.
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => crystal_city_docs()}}
      )

      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:ok, isbn, _meta} =
               ISBNResolver.search_by_title(
                 "The Crystal City: The Tragedy of America's First Internment Camp",
                 "Doris Akers",
                 "THE CRYSTAL CI IT IS ABOUT F DRS",
                 excluded_isbns: ["9781451693669"]
               )

      assert isbn != "9781451693669"
    end

    test "single-doc responses behave exactly as before" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, "9780743273565", meta} =
               ISBNResolver.search_by_title("The Great Gatsby", "Fitzgerald")

      assert meta.title == "The Great Gatsby"
      assert meta.source == :open_library
    end

    test "Google Books scoring carries subtitle and picks the best item" do
      wrong = google_item(title: "The Crystal City", author: "Orson Scott Card")

      right =
        google_item(
          title: "The Train to Crystal City",
          author: "Jan Jarboe Russell",
          identifiers: [%{"type" => "ISBN_13", "identifier" => "9781451693669"}]
        )

      right =
        put_in(
          right,
          ["volumeInfo", "subtitle"],
          "FDR's Secret Internment Camp and America's Only Family " <>
            "Internment Camp During World War II"
        )

      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [wrong, right]}})

      assert {:ok, "9781451693669", meta} =
               ISBNResolver.search_by_title(
                 "The Crystal City: The Tragedy of America's First Internment Camp",
                 "Doris Akers",
                 "THE CRYSTAL CI IT IS ABOUT F DRS"
               )

      assert meta.subtitle =~ "FDR's"
      assert meta.source == :google_books
    end
  end

  # ---------------------------------------------------------------------------
  # search_by_title/4 — plausibility floor
  # ---------------------------------------------------------------------------

  # The production noise-match the plausibility floor exists to fix:
  # VLM signals title="The Tramp's Crystal City", raw_text="THE TRAMP'S
  # CRYSTAL CITY" — Google Books fuzzy-matched the corrupted query and
  # returned "The Crystal Ball a Mystery Story for Girls", which scored
  # 1.5 (overlap 3.0 * 1/3 + raw_text 1.5 * 1/3) and won because
  # max-wins had no floor.
  defp crystal_ball_item do
    google_item(
      title: "The Crystal Ball a Mystery Story for Girls",
      author: "Roy J. Snell",
      categories: ["Fiction"],
      identifiers: [%{"type" => "ISBN_13", "identifier" => "9781532774393"}]
    )
  end

  describe "search_by_title/4 — plausibility floor" do
    test "a single garbage GB candidate below the floor is rejected as :not_found" do
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [crystal_ball_item()]}})

      log =
        capture_resolver_log(fn ->
          assert {:error, :not_found} =
                   ISBNResolver.search_by_title(
                     "The Tramp's Crystal City",
                     nil,
                     "THE TRAMP'S CRYSTAL CITY"
                   )
        end)

      # The floored decision is logged for production debuggability.
      assert log =~ "floored"
      assert log =~ "9781532774393"
    end

    test "multiple garbage candidates all below the floor fall through to :not_found" do
      other_garbage =
        google_item(
          title: "Crystal Growing for Beginners",
          author: "Pat Jones",
          categories: ["Science"],
          identifiers: [%{"type" => "ISBN_13", "identifier" => "9789999999991"}]
        )

      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})

      MockHttpClient.put_response(
        "googleapis.com",
        {:ok, %{"items" => [crystal_ball_item(), other_garbage]}}
      )

      log =
        capture_resolver_log(fn ->
          assert {:error, :not_found} =
                   ISBNResolver.search_by_title(
                     "The Tramp's Crystal City",
                     nil,
                     "THE TRAMP'S CRYSTAL CITY"
                   )
        end)

      # The scored-decision diagnostic still fires for N>=2 before the
      # floor rejects the pick.
      assert log =~ "scored 2 candidates"
      assert log =~ "floored"
    end

    test "the floor is waived when the candidate has author corroboration" do
      # Total score is only the author bonus (1.0, well below 2.5), but
      # a scored author match is strong positive evidence, so the pick
      # survives.
      doc =
        ol_search_doc(
          title: "Completely Different Title",
          author_name: ["Jan Jarboe Russell"],
          isbn: ["9781451693669"],
          subject: []
        )

      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => [doc]}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:ok, "9781451693669", _meta} =
               ISBNResolver.search_by_title("Zork", "Jan Jarboe Russell")
    end

    test "a 3.5-scoring bare-title coincidence stays above the floor (Card case)" do
      # Card is a legitimate pick for a genuinely ambiguous query: no
      # author corroboration (signal author is invented), score exactly
      # 3.5 — must NOT be floored.
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [List.first(crystal_city_docs())]}}
      )

      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:ok, "9781429964500", _meta} =
               ISBNResolver.search_by_title(
                 "The Crystal City: The Tragedy of America's First Internment Camp",
                 "Doris Akers",
                 "THE CRYSTAL CI IT IS ABOUT F DRS"
               )
    end
  end

  # ---------------------------------------------------------------------------
  # search_by_title/4 — excluded_isbns (rejection-retry plumbing)
  # ---------------------------------------------------------------------------

  describe "search_by_title/4 — excluded_isbns" do
    # Rejection-retry: when a user clicks "No, try again" on the
    # identified book, the controller resolves the rejected book ids to
    # ISBNs and threads the list through to the resolver. Without this,
    # a slightly-different VLM title variant on the retry can collapse
    # back to the same wrong OL/GB top match and we'd loop on the same
    # incorrect identification.

    test "skips OL search results whose ISBN matches an excluded entry" do
      excluded = "9781429964500"
      # OL returns the excluded ISBN as its (only) top match. With the
      # exclusion in effect, the candidate is treated as no match and
      # the resolver falls through to {:error, :not_found}.
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc(isbn: [excluded])]}}
      )

      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} =
               ISBNResolver.search_by_title("Crystal City", "Card", nil,
                 excluded_isbns: [excluded]
               )
    end

    test "exclusion match is hyphen/space-insensitive" do
      excluded_with_hyphens = "978-1-4299-6450-0"
      stored_isbn = "9781429964500"

      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc(isbn: [stored_isbn])]}}
      )

      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} =
               ISBNResolver.search_by_title("Crystal City", "Card", nil,
                 excluded_isbns: [excluded_with_hyphens]
               )
    end

    test "returns {:error, :not_found} when all candidate variants resolve to excluded ISBNs" do
      excluded = "9780743273565"

      # Every candidate query variant (title+author, title, etc.) returns
      # the same excluded ISBN — exhaustion path.
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc(isbn: [excluded])]}}
      )

      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} =
               ISBNResolver.search_by_title("Gatsby", "Fitzgerald", nil,
                 excluded_isbns: [excluded]
               )
    end

    test "non-excluded ISBN is returned normally even when excluded_isbns is set" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc(isbn: ["9780743273565"])]}}
      )

      assert {:ok, "9780743273565", _meta} =
               ISBNResolver.search_by_title("Gatsby", "Fitzgerald", nil,
                 excluded_isbns: ["9999999999999"]
               )
    end

    test "empty excluded_isbns list behaves identically to no opts" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, isbn_with, _} =
               ISBNResolver.search_by_title("Gatsby", "Fitzgerald", nil, excluded_isbns: [])

      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, isbn_without, _} = ISBNResolver.search_by_title("Gatsby", "Fitzgerald")
      assert isbn_with == isbn_without
    end
  end
end
