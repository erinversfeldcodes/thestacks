defmodule Stacks.Workers.FetchReviewsJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.AI.MockTogetherClient
  alias Stacks.Enrichment.Reviews
  alias Stacks.Workers.FetchReviewsJob

  import Stacks.Factory

  describe "perform/1 with single book_id" do
    test "fetches and persists review snapshot" do
      book = insert(:book)

      assert :ok == perform_job(FetchReviewsJob, %{book_id: book.id})

      reviews = Reviews.latest_reviews(book.id)
      assert reviews != []

      snapshot = hd(reviews)
      assert snapshot.book_id == book.id
      assert snapshot.source == "goodreads"
      assert snapshot.summary != nil
      assert snapshot.stale_after != nil
    end

    test "persists snapshot without summary when together client fails" do
      book = insert(:book)
      MockTogetherClient.put_response({:error, :circuit_open})

      assert :ok == perform_job(FetchReviewsJob, %{book_id: book.id})

      reviews = Reviews.latest_reviews(book.id)
      assert reviews != []

      snapshot = hd(reviews)
      assert snapshot.book_id == book.id
      assert snapshot.summary == nil
    end
  end

  describe "perform/1 with batch mode" do
    test "processes stale books" do
      book = insert(:book)

      assert :ok == perform_job(FetchReviewsJob, %{batch: true})

      reviews = Reviews.latest_reviews(book.id)
      assert reviews != []
    end

    test "succeeds when no stale books exist" do
      # Insert a book with a fresh review so nothing is stale
      book = insert(:book)
      now = DateTime.utc_now()

      insert(:review_snapshot,
        book: book,
        scraped_at: now,
        stale_after: DateTime.add(now, 30, :day)
      )

      assert :ok == perform_job(FetchReviewsJob, %{batch: true})
    end
  end

  describe "perform/1 with unrecognized args" do
    test "returns :ok for unrecognized args" do
      assert :ok == perform_job(FetchReviewsJob, %{unknown: true})
    end
  end

  describe "summary validation in pipeline" do
    test "strips hallucinated URLs from generated summaries" do
      book = insert(:book)

      MockTogetherClient.put_response(
        {:ok, "Great book! See https://hallucinated-url.com/fake for more."}
      )

      assert :ok == perform_job(FetchReviewsJob, %{book_id: book.id})

      reviews = Reviews.latest_reviews(book.id)
      snapshot = hd(reviews)

      # The hallucinated URL should be stripped since it's not in the source data
      refute String.contains?(snapshot.summary || "", "https://hallucinated-url.com/fake")
    end
  end
end
