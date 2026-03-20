defmodule Stacks.Workers.FetchReviewsJob do
  @moduledoc """
  Oban worker that fetches review data for books and generates LLM summaries.

  ## Modes

  - **Single book:** `%{book_id: "uuid"}` — fetches reviews for this book.
  - **Batch:** `%{batch: true}` — finds all stale books and fetches reviews.

  Review data is summarized via Together AI (circuit-breaker-protected),
  validated for URL hallucinations, and persisted via `Reviews.upsert_snapshot/1`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Enrichment.Reviews
  alias Stacks.Events
  alias Stacks.Monitoring

  @doc false
  @impl true
  def perform(%Oban.Job{args: %{"batch" => true}}) do
    Logger.info("FetchReviewsJob: starting batch review fetch")
    stale_book_ids = Reviews.stale_books(30)

    if Enum.empty?(stale_book_ids) do
      Logger.info("FetchReviewsJob: no stale books found")
      :ok
    else
      Enum.each(stale_book_ids, &fetch_and_persist/1)

      emit_event(length(stale_book_ids))
      :ok
    end
  end

  def perform(%Oban.Job{args: %{"book_id" => book_id}}) do
    Logger.info("FetchReviewsJob: fetching reviews for book_id=#{book_id}")
    fetch_and_persist(book_id)
    emit_event(1)
    :ok
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("FetchReviewsJob: unrecognized args: #{inspect(args)}")
    :ok
  end

  defp fetch_and_persist(book_id) do
    fetcher = review_fetcher()
    review_sources = fetcher.fetch_reviews(book_id)

    together_client = Application.get_env(:core, :together_client, Stacks.AI.TogetherClient)

    Enum.each(review_sources, fn source_data ->
      summary = generate_summary(together_client, source_data)
      now = DateTime.utc_now()

      attrs = %{
        book_id: book_id,
        source: source_data.source,
        source_url: source_data.source_url,
        rating: source_data[:rating],
        rating_count: source_data[:rating_count],
        sentiment_score: source_data[:sentiment_score],
        summary: summary,
        scraped_at: now,
        stale_after: DateTime.add(now, 30, :day)
      }

      case Reviews.upsert_snapshot(attrs) do
        {:ok, _snapshot} ->
          Monitoring.record_success(to_string(source_data.source), "review_source")

        {:error, changeset} ->
          Monitoring.record_failure(
            to_string(source_data.source),
            "review_source",
            inspect(changeset.errors)
          )

          Logger.warning(
            "FetchReviewsJob: upsert failed for book_id=#{book_id} source=#{source_data.source}: #{inspect(changeset.errors)}"
          )
      end
    end)
  end

  defp generate_summary(together_client, source_data) do
    book_context = %{
      title: source_data[:title] || "Unknown",
      author: source_data[:author] || "Unknown"
    }

    case together_client.summarize_reviews(source_data.review_text, book_context) do
      {:ok, raw_summary} ->
        Reviews.validate_summary(raw_summary, source_data.review_text)

      {:error, :circuit_open} ->
        Logger.warning("FetchReviewsJob: Together AI circuit open, skipping summary")
        nil

      {:error, reason} ->
        Logger.warning("FetchReviewsJob: summary generation failed: #{inspect(reason)}")
        nil
    end
  end

  defp emit_event(book_count) do
    Events.emit_safe(%{
      event_type: "enrichment.reviews_scraped",
      aggregate_type: "enrichment",
      aggregate_id: Ecto.UUID.generate(),
      payload: %{book_count: book_count},
      metadata: %{actor: "system:fetch_reviews_job"}
    })

    :ok
  end

  defp review_fetcher do
    Application.get_env(:core, :review_fetcher, Stacks.Enrichment.MockReviewFetcher)
  end
end
