defmodule Stacks.Workers.DiscoverAuthorSourcesJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Discovery.MockBraveClient
  alias Stacks.Enrichment.MockRssFetcher
  alias Stacks.Workers.DiscoverAuthorSourcesJob

  setup do
    on_exit(fn -> MockRssFetcher.clear() end)
    :ok
  end

  # Attaches to Finch's own telemetry so the assertion is about the REAL
  # transport, not about the mock. `[:finch, :request, :start]` fires inside
  # `Finch.request/3` before any pool checkout, so it is reached whether or not
  # the host resolves. Returns the URLs Finch was asked to dial.
  #
  # ⚠️ Telemetry handlers are GLOBAL and run in the caller's process, so with
  # `async: true` a concurrently running test that legitimately uses Finch
  # (e.g. `Stacks.Enrichment.RssFetcherTest`) would otherwise land in this
  # mailbox and fail us for someone else's traffic. `perform_job/2` runs the
  # worker inline in the test process, so filtering on `self() == test_pid`
  # keeps the observation to our own call tree.
  defp record_finch_requests(fun) do
    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      handler_id,
      [:finch, :request, :start],
      fn _event, _measurements, meta, _config ->
        if self() == test_pid do
          send(test_pid, {:finch_request, "#{meta.request.scheme}://#{meta.request.host}"})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_finch_requests([])
  end

  defp collect_finch_requests(acc) do
    receive do
      {:finch_request, url} -> collect_finch_requests([url | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "transport isolation" do
    test "discovery reaches no real host — Finch is never invoked" do
      author = insert(:author)

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "#{author.name} - Official Site",
             url: "https://authorsite.com",
             description: "The official website"
           }
         ]}
      )

      dialled =
        record_finch_requests(fn ->
          assert :ok = perform_job(DiscoverAuthorSourcesJob, %{"author_id" => author.id})
        end)

      assert dialled == [],
             "the job dialled real hosts through Finch: #{inspect(dialled)}"
    end

    test "the feed probe goes through the swappable fetcher, not Finch" do
      author = insert(:author)

      MockBraveClient.put_response(
        {:ok, [%{title: "Site", url: "https://authorsite.com", description: "d"}]}
      )

      MockRssFetcher.put_probe_response({:ok, "https://authorsite.com/feed"})

      dialled =
        record_finch_requests(fn ->
          assert :ok = perform_job(DiscoverAuthorSourcesJob, %{"author_id" => author.id})
        end)

      updated = Core.Repo.get!(Stacks.Books.Author, author.id)

      # The mocked probe's result reached the database, proving the seam is the
      # path the job actually takes...
      assert updated.rss_feed_url == "https://authorsite.com/feed"
      # ...and no real request was issued while doing it.
      assert dialled == []
    end

    test "batch discovery reaches no real host either" do
      insert(:author, website_url: nil)
      insert(:author, website_url: nil)

      MockBraveClient.put_response(
        {:ok, [%{title: "Site", url: "https://authorsite.com", description: "d"}]}
      )

      dialled =
        record_finch_requests(fn ->
          assert :ok = perform_job(DiscoverAuthorSourcesJob, %{"batch" => true})
        end)

      assert dialled == []
    end
  end

  describe "perform/1 with author_id" do
    test "discovers website for an author" do
      author = insert(:author)

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "#{author.name} - Official Site",
             url: "https://authorsite.com",
             description: "The official website"
           }
         ]}
      )

      assert :ok =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })

      updated = Core.Repo.get!(Stacks.Books.Author, author.id)
      assert updated.website_url == "https://authorsite.com"
    end

    test "skips social media URLs" do
      author = insert(:author)

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "Author on Twitter",
             url: "https://twitter.com/author",
             description: "Twitter profile"
           },
           %{
             title: "Author Blog",
             url: "https://authorblog.com",
             description: "Personal blog"
           }
         ]}
      )

      assert :ok =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })

      updated = Core.Repo.get!(Stacks.Books.Author, author.id)
      assert updated.website_url == "https://authorblog.com"
    end

    test "returns cancel when author not found" do
      assert {:cancel, "author not found"} =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => Ecto.UUID.generate()
               })
    end

    test "does not overwrite existing website_url" do
      author = insert(:author, website_url: "https://existing.com")

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "New Site",
             url: "https://newsite.com",
             description: "A new site"
           }
         ]}
      )

      assert :ok =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })

      updated = Core.Repo.get!(Stacks.Books.Author, author.id)
      assert updated.website_url == "https://existing.com"
    end

    test "handles search error gracefully" do
      author = insert(:author)
      MockBraveClient.put_response({:error, :api_key_missing})

      assert {:error, :api_key_missing} =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })
    end
  end

  describe "perform/1 with batch" do
    test "processes all authors without sources" do
      _author1 = insert(:author, website_url: nil)
      _author2 = insert(:author, website_url: nil)

      MockBraveClient.put_response({:ok, []})

      assert :ok = perform_job(DiscoverAuthorSourcesJob, %{"batch" => true})
    end
  end
end
