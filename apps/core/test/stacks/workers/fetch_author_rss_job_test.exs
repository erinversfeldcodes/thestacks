defmodule Stacks.Workers.FetchAuthorRSSJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.FetchAuthorRSSJob

  describe "perform/1" do
    test "processes authors with rss_feed_url (no HTTP call in unit test)" do
      # The actual HTTP fetch would fail in tests without a server,
      # but the job should handle errors gracefully and return :ok
      _author =
        insert(:author,
          rss_feed_url: "https://nonexistent.example.com/feed.xml"
        )

      # The job catches fetch errors and logs warnings, returns :ok
      assert :ok = perform_job(FetchAuthorRSSJob, %{})
    end

    test "returns ok when no authors have rss feeds" do
      insert(:author, rss_feed_url: nil)
      assert :ok = perform_job(FetchAuthorRSSJob, %{})
    end
  end

  describe "fetch_and_parse/1" do
    test "returns error for unreachable URL" do
      assert {:error, _reason} =
               FetchAuthorRSSJob.fetch_and_parse("https://nonexistent.invalid/feed.xml")
    end
  end
end
