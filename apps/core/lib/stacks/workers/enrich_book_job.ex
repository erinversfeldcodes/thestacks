defmodule Stacks.Workers.EnrichBookJob do
  @moduledoc """
  Oban worker that fetches additional metadata for a book.
  Currently a stub — logs the book ID and returns :ok.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl true
  def perform(%Oban.Job{args: %{"book_id" => book_id}}) do
    Logger.info("EnrichBookJob: enriching metadata for book #{book_id} (stub)")
    :ok
  end
end
