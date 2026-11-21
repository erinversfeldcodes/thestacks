defmodule Stacks.Workers.FetchBookReviewsJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Books.MockHttpClient
  alias Stacks.Enrichment
  alias Stacks.Workers.FetchBookReviewsJob

  test "perform fetches OL ratings for the work and stores the sanctioned snapshot" do
    book = insert(:book)

    MockHttpClient.put_response(
      "openlibrary.org/works/OL9W/ratings.json",
      {:ok, %{"summary" => %{"average" => 3.9, "count" => 42}}}
    )

    assert :ok =
             perform_job(FetchBookReviewsJob, %{
               "book_id" => book.id,
               "open_library_work_id" => "OL9W"
             })

    assert [%{source: "open_library", rating_count: 42}] =
             Enrichment.list_sanctioned_reviews(book.id)
  end

  test "perform is a no-op when no Open Library work id is known (nothing to fetch)" do
    book = insert(:book)
    assert :ok = perform_job(FetchBookReviewsJob, %{"book_id" => book.id})
    assert Enrichment.list_sanctioned_reviews(book.id) == []
  end
end
