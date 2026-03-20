defmodule Stacks.Workers.RSSLivenessJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Monitoring
  alias Stacks.Monitoring.SourceHealthCheck
  alias Stacks.Workers.RSSLivenessJob

  describe "perform/1" do
    test "records failure for unreachable RSS feeds" do
      author = insert(:author, rss_feed_url: "https://unreachable.invalid/feed.xml")

      assert :ok = perform_job(RSSLivenessJob, %{})

      source_name = "author_rss:#{author.id}"

      check =
        Core.Repo.one(
          from(s in SourceHealthCheck,
            where: s.source_name == ^source_name
          )
        )

      # Should have recorded a failure since the URL is unreachable
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
  end
end
