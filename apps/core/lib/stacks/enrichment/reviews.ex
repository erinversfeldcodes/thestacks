defmodule Stacks.Enrichment.Reviews do
  @moduledoc """
  Context for review enrichment — manages scraped review snapshots for books
  from external sources (Goodreads, Reddit, StoryGraph, etc.).

  Review snapshots are keyed on `(book_id, source)` and upserted on each
  scrape run. The `stale_books/1` function identifies books that need a
  fresh scrape.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.Book
  alias Stacks.Enrichment
  alias Stacks.Enrichment.ReviewSnapshot

  @doc """
  Inserts a new review snapshot or updates the existing one for the same
  `(book_id, source)` pair.

  Returns `{:ok, snapshot}` on success, `{:error, changeset}` on validation failure.
  """
  @spec upsert_snapshot(map()) :: {:ok, ReviewSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def upsert_snapshot(attrs) do
    %ReviewSnapshot{}
    |> Enrichment.review_snapshot_changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :summary,
           :rating,
           :rating_count,
           :sentiment_score,
           :scraped_at,
           :stale_after,
           :source_url
         ]},
      conflict_target: [:book_id, :source]
    )
  end

  @doc """
  Returns the latest review snapshot per source for the given `book_id`.
  """
  @spec latest_reviews(String.t()) :: [ReviewSnapshot.t()]
  def latest_reviews(book_id) do
    ReviewSnapshot
    |> where([rs], rs.book_id == ^book_id)
    |> order_by([rs], desc: rs.scraped_at)
    |> Repo.all()
  end

  @doc """
  Returns book IDs that have no review snapshot or whose latest snapshot
  is past its `stale_after` threshold.

  The `days` parameter sets the default staleness window for snapshots
  that have no explicit `stale_after` value.
  """
  @spec stale_books(non_neg_integer()) :: [String.t()]
  def stale_books(days \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(b in Book,
      left_join: rs in ReviewSnapshot,
      on: rs.book_id == b.id,
      where:
        is_nil(rs.id) or rs.stale_after < ^cutoff or
          (is_nil(rs.stale_after) and rs.scraped_at < ^cutoff),
      select: type(b.id, :binary_id),
      distinct: true
    )
    |> Repo.all()
  end

  @doc """
  Validates a generated summary against source review data.

  - Extracts URLs from the summary via regex
  - Strips any URL that does not appear in the source data
  - Truncates the result to 500 characters
  """
  @spec validate_summary(String.t(), String.t()) :: String.t()
  def validate_summary(summary, source_data) when is_binary(summary) and is_binary(source_data) do
    url_regex = ~r/https?:\/\/[^\s)>\]]+/

    urls_in_summary = Regex.scan(url_regex, summary) |> List.flatten()

    cleaned =
      Enum.reduce(urls_in_summary, summary, fn url, acc ->
        if String.contains?(source_data, url) do
          acc
        else
          String.replace(acc, url, "")
        end
      end)

    cleaned
    |> String.trim()
    |> String.slice(0, 500)
  end

  def validate_summary(nil, _source_data), do: nil
end
