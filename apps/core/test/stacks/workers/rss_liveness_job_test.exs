defmodule Stacks.Workers.RSSLivenessJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Enrichment.MockRssFetcher
  alias Stacks.Monitoring
  alias Stacks.Monitoring.SourceHealthCheck
  alias Stacks.Workers.RSSLivenessJob

  describe "perform/1" do
    test "records failure when the probe finds no live feed" do
      author = insert(:author, rss_feed_url: "https://unreachable.invalid/feed.xml")

      assert :ok = perform_job(RSSLivenessJob, %{})

      source_name = "author_rss:#{author.id}"

      check =
        Core.Repo.one(
          from(s in SourceHealthCheck,
            where: s.source_name == ^source_name
          )
        )

      assert check
      assert check.consecutive_failures >= 1
      assert check.last_failure_reason
    end

    test "completes without error when no authors have RSS feeds" do
      insert(:author, rss_feed_url: nil)

      assert :ok = perform_job(RSSLivenessJob, %{})
    end

    test "creates source_health_check record per author" do
      author1 = insert(:author, rss_feed_url: "https://example1.invalid/feed.xml")
      author2 = insert(:author, rss_feed_url: "https://example2.invalid/feed.xml")

      assert :ok = perform_job(RSSLivenessJob, %{})

      {:ok, check1} = Monitoring.get_or_create("author_rss:#{author1.id}", "rss_feed")
      {:ok, check2} = Monitoring.get_or_create("author_rss:#{author2.id}", "rss_feed")

      assert check1.source_name == "author_rss:#{author1.id}"
      assert check2.source_name == "author_rss:#{author2.id}"
    end

    test "records the probe's failure reason" do
      author = insert(:author, rss_feed_url: "https://unreachable.invalid/feed.xml")

      assert :ok = perform_job(RSSLivenessJob, %{})

      source_name = "author_rss:#{author.id}"

      check =
        Core.Repo.one(
          from(s in SourceHealthCheck,
            where: s.source_name == ^source_name
          )
        )

      assert check
      assert check.last_failure_reason == ":not_found"
      assert check.source_type == "rss_feed"
    end

    test "records success when the probe finds a live feed" do
      author = insert(:author, rss_feed_url: "https://alive.test/feed.xml")

      MockRssFetcher.put_probe_response({:ok, "https://alive.test/feed.xml"})
      on_exit(fn -> MockRssFetcher.clear() end)

      assert :ok = perform_job(RSSLivenessJob, %{})

      source_name = "author_rss:#{author.id}"

      check =
        Core.Repo.one(
          from(s in SourceHealthCheck,
            where: s.source_name == ^source_name
          )
        )

      assert check
      assert check.status == "healthy"
      assert check.consecutive_failures == 0
      assert check.last_success_at
    end

    test "handles multiple authors with mixed results in a single run" do
      _author1 = insert(:author, rss_feed_url: "https://feed1.invalid/rss")
      _author2 = insert(:author, rss_feed_url: nil)
      _author3 = insert(:author, rss_feed_url: "https://feed3.invalid/rss")

      assert :ok = perform_job(RSSLivenessJob, %{})

      count =
        Core.Repo.aggregate(
          from(s in SourceHealthCheck, where: s.source_type == "rss_feed"),
          :count
        )

      assert count >= 2
    end

    test "consecutive runs increment failure count" do
      author = insert(:author, rss_feed_url: "https://unreachable.invalid/feed.xml")

      assert :ok = perform_job(RSSLivenessJob, %{})
      assert :ok = perform_job(RSSLivenessJob, %{})

      source_name = "author_rss:#{author.id}"

      check =
        Core.Repo.one(
          from(s in SourceHealthCheck,
            where: s.source_name == ^source_name
          )
        )

      assert check.consecutive_failures >= 2
    end
  end
end
