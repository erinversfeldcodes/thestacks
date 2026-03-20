defmodule Stacks.Enrichment.Handlers.AuthorDiscoveryHandlerTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Enrichment.Handlers.AuthorDiscoveryHandler
  alias Stacks.Workers.DiscoverAuthorSourcesJob

  describe "handle_event/1" do
    test "enqueues discovery job when author has no sources" do
      author = insert(:author, website_url: nil, rss_feed_url: nil)
      book = insert(:book, author: author)

      assert :ok =
               AuthorDiscoveryHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_id: book.id
               })

      assert_enqueued(worker: DiscoverAuthorSourcesJob, args: %{author_id: author.id})
    end

    test "does not enqueue when author already has sources" do
      author =
        insert(:author,
          website_url: "https://example.com",
          rss_feed_url: "https://example.com/feed"
        )

      book = insert(:book, author: author)

      assert :ok =
               AuthorDiscoveryHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_id: book.id
               })

      refute_enqueued(worker: DiscoverAuthorSourcesJob)
    end

    test "returns ok when book has no author" do
      book = insert(:book, author: nil)

      assert :ok =
               AuthorDiscoveryHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_id: book.id
               })
    end
  end
end
