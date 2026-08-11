defmodule Stacks.Workers.RSSLivenessJob do
  @moduledoc """
      Weekly Oban cron worker that checks the liveness of author RSS feed URLs.

      Probes each author's `rss_feed_url` (HTTP HEAD via the seamed
      `Stacks.Enrichment.RssFetcher`, c) and records the result in
      `source_health_checks` via `Stacks.Monitoring`. A 2xx response is recorded
      as success; non-2xx statuses, timeouts, and errors are recorded as
      failures.

      Scheduled via cron: `{"0 3 * * 0", Stacks.Workers.RSSLivenessJob}` (Sundays
      at 03:00 UTC).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Enrichment.Authors
  alias Stacks.Monitoring

  @impl true
  def perform(%Oban.Job{}) do
    authors = Authors.authors_with_rss()
    Logger.info("RSSLivenessJob: checking #{length(authors)} RSS feed URLs")

    Enum.each(authors, &check_feed/1)

    :ok
  end

  defp check_feed(author) do
    source_name = "author_rss:#{author.id}"

    case rss_fetcher().probe(author.rss_feed_url) do
      {:ok, _url} ->
        Monitoring.record_success(source_name, "rss_feed")

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

  defp rss_fetcher do
    Application.get_env(:core, :rss_fetcher, Stacks.Enrichment.RssFetcher)
  end
end
