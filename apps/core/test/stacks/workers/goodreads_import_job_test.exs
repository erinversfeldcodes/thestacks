defmodule Stacks.Workers.GoodreadsImportJobTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Books.MockHttpClient
  alias Stacks.Imports
  alias Stacks.Shelving
  alias Stacks.Workers.GoodreadsImportJob
  alias Stacks.Workers.RegenerateFeedJob

  @fixture Path.expand("../../support/fixtures/goodreads_library_export.csv", __DIR__)

  setup do
    original_http = Application.get_env(:core, :isbn_http_client)
    Application.put_env(:core, :isbn_http_client, MockHttpClient)

    :fuse.reset(:open_library_fuse)
    :fuse.reset(:google_books_fuse)

    on_exit(fn ->
      Application.put_env(:core, :isbn_http_client, original_http)
      :fuse.reset(:open_library_fuse)
      :fuse.reset(:google_books_fuse)
    end)

    :ok
  end

  defp ol_book(isbn, title, author) do
    {"ISBN:#{isbn}",
     %{
       "title" => title,
       "authors" => [%{"name" => author}],
       "publish_date" => "1991",
       "number_of_pages" => 400,
       "subjects" => ["Fiction"],
       "key" => "/books/OL#{isbn}M"
     }}
  end

  defp stub_fixture_isbns do
    books =
      Map.new([
        ol_book("9780141036144", "1984", "George Orwell"),
        ol_book("9780261102217", "The Fellowship of the Ring", "J.R.R. Tolkien"),
        ol_book("9780261102361", "The Two Towers", "J.R.R. Tolkien")
      ])

    MockHttpClient.put_response("openlibrary.org/api/books", {:ok, books})
  end

  defp create_import(user) do
    {:ok, import} = Imports.create_import(user.id, "export.csv", File.read!(@fixture))
    import
  end

  defp run_to_completion(import) do
    assert :ok = perform_job(GoodreadsImportJob, %{"import_id" => import.id, "offset" => 0})
    assert :ok = perform_job(GoodreadsImportJob, %{"import_id" => import.id, "offset" => 5})
  end

  describe "the full fixture import" do
    setup do
      stub_fixture_isbns()
      user = insert(:user)
      import = create_import(user)
      run_to_completion(import)
      %{user: user, import: Imports.get_import(user.id, import.id)}
    end

    test "shelves the verifiable rows onto the mapping", %{user: user} do
      for {bookshelf, title} <- [
            {"library", "1984"},
            {"reading_pile", "The Fellowship of the Ring"},
            {"antilibrary", "The Two Towers"}
          ] do
        placements = Shelving.get_bookshelf_books(user.id, bookshelf)

        assert Enum.any?(placements, &(&1.book.title == title)),
               "expected #{inspect(title)} on #{bookshelf}"
      end
    end

    test "the ISBN hard gate holds: unknown and missing ISBNs stay out", %{
      user: user,
      import: import
    } do
      {:ok, rows} = Imports.list_rows(user.id, import.id)
      by_number = Map.new(rows, &{&1.row_number, &1})

      assert by_number[4].outcome == "unverified"
      assert by_number[4].reason =~ "not found"

      assert by_number[5].outcome == "unverified"
      assert by_number[5].reason =~ "no valid ISBN"

      assert Shelving.get_bookshelf_books(user.id, "wishlist") == []
    end

    test "placements carry provenance and the reader's Goodreads history", %{
      user: user,
      import: import
    } do
      {:ok, rows} = Imports.list_rows(user.id, import.id)
      orwell_row = Enum.find(rows, &(&1.row_number == 1))
      placement = Core.Repo.get!(Stacks.Shelving.Placement, orwell_row.placement_id)

      assert placement.source == "goodreads_import"
      assert placement.personal_rating == 5
      assert placement.notes == "Bleak and necessary.\n\nLent to Sam."
      assert placement.formats == ["paperback"]
      assert placement.reading_status == "completed"
      assert DateTime.compare(placement.finished_at, ~U[2023-06-14 00:00:00Z]) == :eq
      assert DateTime.compare(placement.placed_at, ~U[2023-01-02 00:00:00Z]) == :eq
    end

    test "finalises with counts and stamps", %{import: import} do
      assert import.status == "complete"
      assert import.started_at
      assert import.finished_at
      assert import.row_count == 5
      assert import.processed_count == 5
      assert import.shelved_count == 3
      assert import.unverified_count == 2
      assert import.duplicate_count == 0
      assert import.unreadable_count == 0
    end

    test "feed regeneration is coalesced: one job per touched bookshelf, not per placement" do
      jobs = all_enqueued(worker: RegenerateFeedJob)

      assert jobs |> Enum.map(& &1.args["bookshelf_name"]) |> Enum.sort() ==
               ["antilibrary", "library", "reading_pile"]
    end
  end

  describe "dedup" do
    test "a book already on the destination bookshelf reports duplicate, not a second copy" do
      stub_fixture_isbns()
      user = insert(:user)

      {:ok, orwell} =
        Stacks.Books.create(%{
          "isbn" => "9780141036144",
          "title" => "1984",
          "author" => "George Orwell"
        })

      {:ok, _} = Shelving.place_book(user.id, orwell.id, "library")

      import = create_import(user)
      run_to_completion(import)

      {:ok, rows} = Imports.list_rows(user.id, import.id, outcome: "duplicate")
      assert [row] = rows
      assert row.row_number == 1
      assert row.book_id == orwell.id
      assert row.reason =~ "library"

      placements = Shelving.get_bookshelf_books(user.id, "library")
      assert length(Enum.filter(placements, &(&1.book.id == orwell.id))) == 1
    end
  end

  describe "resolver outage (fuse-open)" do
    setup do
      MockHttpClient.put_response("openlibrary.org", {:error, :unexpected_status})
      MockHttpClient.put_response("googleapis.com", {:error, :unexpected_status})
      :ok
    end

    test "the batch retries instead of marking rows unverified" do
      user = insert(:user)
      import = create_import(user)

      assert {:error, message} =
               perform_job(GoodreadsImportJob, %{"import_id" => import.id, "offset" => 0})

      assert message =~ "resolver unavailable"

      {:ok, rows} = Imports.list_rows(user.id, import.id, outcome: "unverified")
      assert rows == []

      import = Imports.get_import(user.id, import.id)
      assert import.status == "running"
    end

    test "on the final attempt the import fails — with processed outcomes kept" do
      user = insert(:user)
      import = create_import(user)

      assert :ok =
               perform_job(
                 GoodreadsImportJob,
                 %{"import_id" => import.id, "offset" => 0},
                 attempt: 5,
                 max_attempts: 5
               )

      import = Imports.get_import(user.id, import.id)
      assert import.status == "failed"
      assert import.finished_at
    end

    test "a retry resumes: rows with outcomes already written are skipped" do
      user = insert(:user)
      import = create_import(user)
      {:ok, [first | _]} = Imports.list_rows(user.id, import.id)

      Imports.record_outcome(first, "shelved")

      assert {:error, _} =
               perform_job(GoodreadsImportJob, %{"import_id" => import.id, "offset" => 0})

      {:ok, rows} = Imports.list_rows(user.id, import.id)
      assert Enum.find(rows, &(&1.row_number == 1)).outcome == "shelved"
    end
  end

  describe "terminal states" do
    test "cancels for a vanished or already-finished import" do
      assert {:cancel, _} =
               perform_job(GoodreadsImportJob, %{
                 "import_id" => Ecto.UUID.generate(),
                 "offset" => 0
               })

      user = insert(:user)
      import = create_import(user)
      {:ok, _} = Imports.finalize(import, "complete")

      assert {:cancel, message} =
               perform_job(GoodreadsImportJob, %{"import_id" => import.id, "offset" => 0})

      assert message =~ "complete"
    end
  end
end
