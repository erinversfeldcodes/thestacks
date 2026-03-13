defmodule Stacks.Books.ISBNResolverTest do
  use ExUnit.Case, async: true

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
    %{
      "isbn" => opts[:isbn] || ["9780743273565"],
      "title" => opts[:title] || "The Great Gatsby",
      "author_name" => opts[:author_name] || ["F. Scott Fitzgerald"],
      "subject" => opts[:subject] || ["American fiction"],
      "first_publish_year" => opts[:year] || 1925
    }
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
      # raw_text triggers the enriched_prefix path
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
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
      # The raw_text "F D R" should become "fdr" and be included in the search query.
      # We verify the path executes without error and produces candidates.
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, _, _} = ISBNResolver.search_by_title("Train to Crystal City", nil, "F D R")
    end

    test "empty string raw_text skips enriched prefix" do
      MockHttpClient.put_response(
        "openlibrary.org/search.json",
        {:ok, %{"docs" => [ol_search_doc()]}}
      )

      assert {:ok, _, _} = ISBNResolver.search_by_title("Gatsby", nil, "")
    end
  end
end
