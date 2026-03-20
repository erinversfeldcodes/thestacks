defmodule Stacks.Workers.FetchAuthorRSSJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Enrichment.MockRssFetcher
  alias Stacks.Workers.FetchAuthorRSSJob

  setup do
    on_exit(fn -> MockRssFetcher.clear() end)
    :ok
  end

  describe "perform/1 with mock RSS fetcher" do
    test "parses RSS entries with RFC 2822 dates and emits event" do
      now = DateTime.utc_now()
      recent_date = Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S +0000")

      insert(:author, rss_feed_url: "https://author.example.com/feed.xml")

      MockRssFetcher.put_response(
        {:ok,
         %{
           entries: [
             %{
               title: "New Blog Post",
               url: "https://author.example.com/new-post",
               updated: recent_date,
               summary: "A great new post about writing."
             }
           ]
         }}
      )

      assert :ok = perform_job(FetchAuthorRSSJob, %{})

      # Verify the event was emitted
      assert Core.Repo.aggregate(
               from(e in "event_log",
                 prefix: "op",
                 where: e.event_type == "enrichment.author_updated"
               ),
               :count
             ) == 1
    end

    test "filters out entries older than 24 hours" do
      old_date = "Mon, 01 Jan 2024 10:00:00 +0000"

      insert(:author, rss_feed_url: "https://author.example.com/feed.xml")

      MockRssFetcher.put_response(
        {:ok,
         %{
           entries: [
             %{
               title: "Old Post",
               url: "https://author.example.com/old-post",
               updated: old_date,
               summary: "An old post."
             }
           ]
         }}
      )

      assert :ok = perform_job(FetchAuthorRSSJob, %{})

      # No event should be emitted since all entries are older than 24h
      assert Core.Repo.aggregate(
               from(e in "event_log",
                 prefix: "op",
                 where: e.event_type == "enrichment.author_updated"
               ),
               :count
             ) == 0
    end

    test "returns ok when no authors have rss feeds" do
      insert(:author, rss_feed_url: nil)
      assert :ok = perform_job(FetchAuthorRSSJob, %{})
    end

    test "handles fetch errors gracefully" do
      insert(:author, rss_feed_url: "https://author.example.com/feed.xml")

      MockRssFetcher.put_response({:error, {:unexpected_status, 500}})

      assert :ok = perform_job(FetchAuthorRSSJob, %{})
    end
  end

  describe "try_rfc2822/1" do
    test "parses standard RFC 2822 date" do
      result = FetchAuthorRSSJob.try_rfc2822("Thu, 20 Mar 2026 10:00:00 +0000")
      assert %DateTime{} = result
      assert result.year == 2026
      assert result.month == 3
      assert result.day == 20
      assert result.hour == 10
    end

    test "parses RFC 2822 date with timezone offset" do
      result = FetchAuthorRSSJob.try_rfc2822("Thu, 20 Mar 2026 10:00:00 -0500")
      assert %DateTime{} = result
      # Converted to UTC: 10:00 -0500 = 15:00 UTC
      assert result.hour == 15
      assert result.time_zone == "Etc/UTC"
    end

    test "returns nil for unparseable string" do
      assert is_nil(FetchAuthorRSSJob.try_rfc2822("not a date"))
    end
  end

  describe "parse_date/1" do
    test "parses ISO 8601 date" do
      result = FetchAuthorRSSJob.parse_date("2026-03-20T10:00:00Z")
      assert %DateTime{} = result
      assert result.year == 2026
    end

    test "parses RFC 2822 date" do
      result = FetchAuthorRSSJob.parse_date("Thu, 20 Mar 2026 10:00:00 +0000")
      assert %DateTime{} = result
      assert result.year == 2026
    end

    test "returns nil for nil" do
      assert is_nil(FetchAuthorRSSJob.parse_date(nil))
    end

    test "returns nil for non-binary" do
      assert is_nil(FetchAuthorRSSJob.parse_date(123))
    end
  end

  describe "filter_recent_entries/1" do
    test "keeps entries from within the last 24 hours" do
      recent = DateTime.add(DateTime.utc_now(), -1, :hour)
      old = DateTime.add(DateTime.utc_now(), -2, :day)

      entries = [
        %{title: "Recent", published: recent, url: "", summary: ""},
        %{title: "Old", published: old, url: "", summary: ""}
      ]

      result = FetchAuthorRSSJob.filter_recent_entries(entries)
      assert length(result) == 1
      assert hd(result).title == "Recent"
    end

    test "filters out entries with nil published date" do
      entries = [%{title: "No Date", published: nil, url: "", summary: ""}]
      assert FetchAuthorRSSJob.filter_recent_entries(entries) == []
    end
  end
end
