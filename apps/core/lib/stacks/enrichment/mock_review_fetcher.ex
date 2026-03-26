defmodule Stacks.Enrichment.MockReviewFetcher do
  @moduledoc """
  Mock review data fetcher for development and testing.

  Returns static Goodreads-style review data. In production, this will be
  replaced by a real fetcher that scrapes external review sources.
  """

  @behaviour Stacks.Enrichment.ReviewFetcherBehaviour

  @impl true
  def fetch_reviews(book_id) do
    [
      %{
        source: "goodreads",
        source_url: "https://goodreads.com/book/show/#{book_id}",
        review_text:
          "Readers found this book engaging and well-written. The plot was compelling with strong character development.",
        rating: 4.2,
        rating_count: 1250,
        sentiment_score: 0.78,
        title: "Unknown",
        author: "Unknown"
      }
    ]
  end
end
