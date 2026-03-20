defmodule Stacks.Workers.RSSLivenessJob do
  @moduledoc """
  Weekly Oban cron worker that checks the liveness of author RSS feed URLs.

  Sends an HTTP HEAD request to each author's `rss_feed_url` and records the
  result in `source_health_checks` via `Stacks.Monitoring`. A 2xx response
  is recorded as success; 404, 410, timeouts, and errors are recorded as
  failures.

  Scheduled via cron: `{"0 3 * * 0", Stacks.Workers.RSSLivenessJob}` (Sundays
  at 03:00 UTC).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Enrichment.Authors
  alias Stacks.Monitoring

  @head_timeout 5_000

  @impl true
  def perform(%Oban.Job{}) do
    authors = Authors.authors_with_rss()
    Logger.info("RSSLivenessJob: checking #{length(authors)} RSS feed URLs")

    Enum.each(authors, &check_feed/1)

    :ok
  end

  defp check_feed(author) do
    source_name = "author_rss:#{author.id}"

    case head_request(author.rss_feed_url) do
      {:ok, status} when status in 200..299 ->
        Monitoring.record_success(source_name, "rss_feed")

      {:ok, status} ->
        Monitoring.record_failure(
          source_name,
          "rss_feed",
          "HTTP #{status}"
        )

      {:error, reason} ->
        Monitoring.record_failure(
          source_name,
          "rss_feed",
          inspect(reason)
        )
    end
  rescue
    exception ->
      Logger.warning(
        "RSSLivenessJob: check failed for author #{author.id}: #{Exception.message(exception)}"
      )

      Monitoring.record_failure(
        "author_rss:#{author.id}",
        "rss_feed",
        Exception.message(exception)
      )
  end

  defp head_request(url) do
    req = Finch.build(:head, url)

    case Finch.request(req, Stacks.Finch, receive_timeout: @head_timeout) do
      {:ok, %Finch.Response{status: status}} ->
        {:ok, status}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
