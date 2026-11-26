defmodule Stacks.Workers.FetchBookReviewsJob do
  @moduledoc """
  The trigger for the sanctioned review vertical: fetch a book's
  Open Library ratings and store them as its `open_library` review snapshot.

  Open Library reviews are per-WORK, so this needs the OL work id resolved at
  enrichment time (the ISBN resolver already produces it). A job with no work id
  has nothing to fetch — Open Library ratings do not exist without the work — so
  that is a clean no-op, not a failure.

  A missing-ratings result is also not a failure: plenty of works carry no
  ratings, and retrying would not change that.
  """
  use Stacks.Worker, scope: :system, queue: :default, max_attempts: 3

  alias Stacks.Enrichment

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"book_id" => book_id, "open_library_work_id" => work_id}})
      when is_binary(book_id) and is_binary(work_id) and work_id != "" do
    case Enrichment.fetch_open_library_reviews(book_id, work_id) do
      {:ok, _snapshot} -> :ok
      {:error, :no_ratings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: :ok

  @doc "Enqueue a review fetch for a book whose Open Library work id is known."
  @spec enqueue(binary(), binary()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(book_id, work_id) do
    %{book_id: book_id, open_library_work_id: work_id}
    |> new()
    |> Oban.insert()
  end
end
