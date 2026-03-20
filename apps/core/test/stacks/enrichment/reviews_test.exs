defmodule Stacks.Enrichment.ReviewsTest do
  use Core.DataCase, async: true

  alias Stacks.Enrichment.Reviews
  alias Stacks.Enrichment.ReviewSnapshot

  import Stacks.Factory

  describe "upsert_snapshot/1" do
    test "inserts a new review snapshot" do
      book = insert(:book)

      attrs = %{
        book_id: book.id,
        source: :goodreads,
        source_url: "https://goodreads.com/book/show/123",
        rating: 4.2,
        rating_count: 1250,
        sentiment_score: 0.78,
        summary: "A great read.",
        scraped_at: DateTime.utc_now(),
        stale_after: DateTime.add(DateTime.utc_now(), 30, :day)
      }

      assert {:ok, %ReviewSnapshot{} = snapshot} = Reviews.upsert_snapshot(attrs)
      assert snapshot.book_id == book.id
      assert snapshot.source == :goodreads
      assert snapshot.summary == "A great read."
      assert snapshot.rating == 4.2
    end

    test "upserts on conflict (book_id + source)" do
      book = insert(:book)
      now = DateTime.utc_now()

      attrs = %{
        book_id: book.id,
        source: :goodreads,
        source_url: "https://goodreads.com/book/show/123",
        rating: 4.0,
        rating_count: 100,
        scraped_at: now
      }

      assert {:ok, %ReviewSnapshot{}} = Reviews.upsert_snapshot(attrs)

      updated_attrs = %{
        book_id: book.id,
        source: :goodreads,
        source_url: "https://goodreads.com/book/show/123-updated",
        rating: 4.5,
        rating_count: 200,
        summary: "Updated summary.",
        scraped_at: DateTime.add(now, 1, :day)
      }

      assert {:ok, %ReviewSnapshot{} = updated} = Reviews.upsert_snapshot(updated_attrs)
      assert updated.rating == 4.5
      assert updated.rating_count == 200
      assert updated.summary == "Updated summary."
      assert updated.source_url == "https://goodreads.com/book/show/123-updated"
    end

    test "validates required fields" do
      assert {:error, changeset} = Reviews.upsert_snapshot(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors[:book_id]
      assert "can't be blank" in errors[:source]
      assert "can't be blank" in errors[:source_url]
      assert "can't be blank" in errors[:scraped_at]
    end

    test "validates summary max length" do
      book = insert(:book)
      long_summary = String.duplicate("a", 501)

      attrs = %{
        book_id: book.id,
        source: :goodreads,
        source_url: "https://goodreads.com/book/show/123",
        summary: long_summary,
        scraped_at: DateTime.utc_now()
      }

      assert {:error, changeset} = Reviews.upsert_snapshot(attrs)
      errors = errors_on(changeset)
      assert errors[:summary] != nil
    end

    test "allows different sources for the same book" do
      book = insert(:book)
      now = DateTime.utc_now()

      goodreads = %{
        book_id: book.id,
        source: :goodreads,
        source_url: "https://goodreads.com/book/show/123",
        scraped_at: now
      }

      reddit = %{
        book_id: book.id,
        source: :reddit,
        source_url: "https://reddit.com/r/books/123",
        scraped_at: now
      }

      assert {:ok, _} = Reviews.upsert_snapshot(goodreads)
      assert {:ok, _} = Reviews.upsert_snapshot(reddit)

      reviews = Reviews.latest_reviews(book.id)
      assert length(reviews) == 2
    end
  end

  describe "latest_reviews/1" do
    test "returns all review snapshots for a book" do
      book = insert(:book)
      _snapshot = insert(:review_snapshot, book: book, source: :goodreads)

      reviews = Reviews.latest_reviews(book.id)
      assert length(reviews) == 1
      assert hd(reviews).book_id == book.id
    end

    test "returns empty list when no reviews exist" do
      assert [] == Reviews.latest_reviews(Ecto.UUID.generate())
    end
  end

  describe "stale_books/1" do
    test "returns book IDs with no review snapshots" do
      book = insert(:book)

      stale = Reviews.stale_books(30)
      assert book.id in stale
    end

    test "does not return books with fresh reviews" do
      book = insert(:book)
      now = DateTime.utc_now()

      insert(:review_snapshot,
        book: book,
        scraped_at: now,
        stale_after: DateTime.add(now, 30, :day)
      )

      stale = Reviews.stale_books(30)
      refute book.id in stale
    end

    test "returns book IDs with stale reviews (past stale_after)" do
      book = insert(:book)
      past = DateTime.add(DateTime.utc_now(), -60, :day)

      insert(:review_snapshot,
        book: book,
        scraped_at: past,
        stale_after: DateTime.add(past, 30, :day)
      )

      stale = Reviews.stale_books(30)
      assert book.id in stale
    end
  end

  describe "validate_summary/2" do
    test "passes through clean summary" do
      summary = "This is a great book with compelling characters."
      assert Reviews.validate_summary(summary, "source data") == summary
    end

    test "strips hallucinated URLs" do
      summary = "Great book. See https://fake.com/review for more."
      source = "Original review text without that URL."

      result = Reviews.validate_summary(summary, source)
      refute String.contains?(result, "https://fake.com/review")
    end

    test "preserves URLs that exist in source data" do
      url = "https://goodreads.com/review/123"
      summary = "Great book. See #{url} for details."
      source = "Review from #{url} says it's wonderful."

      result = Reviews.validate_summary(summary, source)
      assert String.contains?(result, url)
    end

    test "truncates to 500 characters" do
      long_summary = String.duplicate("a", 600)
      result = Reviews.validate_summary(long_summary, "source")
      assert String.length(result) == 500
    end

    test "returns nil for nil summary" do
      assert Reviews.validate_summary(nil, "source") == nil
    end
  end
end
