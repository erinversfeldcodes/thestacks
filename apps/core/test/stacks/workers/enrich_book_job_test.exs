defmodule Stacks.Workers.EnrichBookJobTest do
  @moduledoc """
  Tests for Stacks.Workers.EnrichBookJob.

  The worker is enqueued by `Stacks.Moderation.store_book/3` when a
  checksum-valid ISBN takes the fast path — the synchronous OL/GB call
  is skipped, a placeholder book is inserted, and this worker fills in
  the real metadata asynchronously. Tests verify:

    * Valid ISBN with a placeholder book → title + cover get filled in
    * Unknown ISBN → :ok, no-op (book row doesn't exist yet)
    * Already-enriched book → :ok, no-op (idempotent on retry)
    * Legacy book_id arg shape → resolved via BookEdition join
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Books.MockHttpClient
  alias Stacks.Workers.EnrichBookJob

  describe "perform/1 — isbn arg" do
    test "enriches a placeholder book with OL metadata" do
      isbn = "9780743273565"

      # Seed a placeholder book row the way Moderation does on the fast path.
      {:ok, book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      # Prime the mock so the resolver returns real metadata.
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "The Great Gatsby",
             "authors" => [%{"name" => "F. Scott Fitzgerald"}],
             "number_of_pages" => 180,
             "cover" => %{"large" => "https://covers.openlibrary.org/b/id/1-L.jpg"},
             "publishers" => [%{"name" => "Scribner"}],
             "publish_date" => "1925"
           }
         }}
      )

      assert :ok = perform_job(EnrichBookJob, %{"isbn" => isbn})

      updated = Repo.get!(Stacks.Books.Book, book.id)
      assert updated.title == "The Great Gatsby"
    end

    test "links the resolver author to the book via author_id" do
      # Regression: previously `update_book` only cast title/description,
      # so an OL response with an authors list left `op.books.author_id`
      # null. The deployed preview showed
      # `curl /api/books/isbn/9780156001311` returning `"author": null`
      # for "The Name of the Rose" despite OL carrying Umberto Eco.
      isbn = "9780156001311"

      {:ok, book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "The Name of the Rose",
             "authors" => [%{"name" => "Umberto Eco"}],
             "publish_date" => "1980"
           }
         }}
      )

      assert :ok = perform_job(EnrichBookJob, %{"isbn" => isbn})

      updated = Repo.get!(Book, book.id) |> Repo.preload(:author)
      assert updated.title == "The Name of the Rose"
      assert updated.author_id != nil
      assert updated.author.name == "Umberto Eco"
    end

    test "enrichment stops the edition claiming nothing ever verified it (#344)" do
      # `verification_source` is a CURRENT state — "no external source has
      # confirmed this ISBN YET" — not a record of how the ISBN first arrived.
      # Left unwritten here it was permanent: a book that entered on the barcode
      # fast path and was identified by Open Library seconds later went on saying
      # for ever that nobody had verified it. That makes the column useless for
      # the one question it exists to answer, and since #344 renders a
      # provisional book distinguishably off exactly this value, it would show a
      # fully identified book as unidentified.
      isbn = "9780679783268"

      {:ok, book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "verification_source" => "barcode_unverified",
          "visibility_tier" => "public"
        })

      edition = hd(book.editions)

      assert edition.verification_source == "barcode_unverified",
             "precondition: the fast path recorded that nothing external had confirmed this ISBN"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "Pride and Prejudice",
             "authors" => [%{"name" => "Jane Austen"}],
             "key" => "/works/OL66554W"
           }
         }}
      )

      assert :ok = perform_job(EnrichBookJob, %{"isbn" => isbn})

      reloaded = Repo.get!(Stacks.Books.BookEdition, edition.id)

      refute reloaded.verification_source == "barcode_unverified",
             "Open Library has now confirmed this ISBN; the row must stop saying otherwise"

      assert reloaded.verification_source == "open_library"
      assert Repo.get!(Book, book.id).title == "Pride and Prejudice"
    end

    test "enrichment stores the cross-reference id its provenance claim is read off (#346)" do
      # The other half of #346. The fast path resolves no metadata, so
      # `Moderation.build_book_attrs/4` has no identifier to hand the create —
      # THIS job is the OL/GB round-trip for those rows. It wrote the
      # `verification_source` claim above while dropping the two ids that claim
      # is derived from, so a fast-path edition ended up saying "open_library"
      # with `open_library_id` NULL: the claim and its evidence stored apart,
      # and only the claim ever asserted.
      isbn = "9780141439518"

      {:ok, book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "verification_source" => "barcode_unverified",
          "visibility_tier" => "public"
        })

      edition = hd(book.editions)

      assert is_nil(edition.open_library_id),
             "precondition: the fast path had no identifier to write"

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "Pride and Prejudice",
             "authors" => [%{"name" => "Jane Austen"}],
             "key" => "/books/OL24236411M"
           }
         }}
      )

      assert :ok = perform_job(EnrichBookJob, %{"isbn" => isbn})

      reloaded = Repo.get!(Stacks.Books.BookEdition, edition.id)

      assert reloaded.open_library_id == "/books/OL24236411M",
             "enrichment resolved the ISBN and threw the cross-reference away"

      assert reloaded.verification_source == "open_library",
             "the claim and the id it is read off must land on the row together"
    end

    test "no-ops when book row for the ISBN doesn't exist" do
      # No book seeded — worker should log + succeed, not crash.
      assert :ok = perform_job(EnrichBookJob, %{"isbn" => "9780000000000"})
    end

    test "no-ops when book already has a real (non-placeholder) title" do
      isbn = "9780141439518"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "Already Enriched",
          "visibility_tier" => "public"
        })

      # Worker should short-circuit without calling the resolver. No
      # mock response registered — if it DID hit the resolver, the
      # result would be :not_found which isn't an error.
      assert :ok = perform_job(EnrichBookJob, %{"isbn" => isbn})
    end
  end

  describe "perform/1 — legacy book_id arg" do
    test "resolves ISBN from the first edition and delegates" do
      isbn = "9780452284234"

      {:ok, book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "Legacy Path Worked",
             "authors" => [%{"name" => "Test"}],
             "publish_date" => "2000"
           }
         }}
      )

      assert :ok = perform_job(EnrichBookJob, %{"book_id" => book.id})

      updated = Repo.get!(Stacks.Books.Book, book.id)
      assert updated.title == "Legacy Path Worked"
    end

    test "no-ops when book_id has no associated edition" do
      # Book without edition — shouldn't happen in production but tests
      # resilience against legacy args.
      assert :ok = perform_job(EnrichBookJob, %{"book_id" => Ecto.UUID.generate()})
    end
  end
end
