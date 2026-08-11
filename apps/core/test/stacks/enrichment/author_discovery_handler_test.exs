defmodule Stacks.Enrichment.Handlers.AuthorDiscoveryHandlerTest do
  @moduledoc """
    Tests for the no-op handler. Per-book `DiscoverAuthorSourcesJob`
    enqueue was removed because it exhausted Brave Search's free-tier
    quota (2000/month ≈ 67/day) within hours of traffic. Batch-mode
    discovery now runs from cron — see `config/config.exs`.

    These tests verify the handler behaves as a no-op for every event
    shape it might receive, so the registry wiring can stay in place
    without side-effects.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Enrichment.Handlers.AuthorDiscoveryHandler
  alias Stacks.Workers.DiscoverAuthorSourcesJob

  describe "handle_event/1" do
    test "does not enqueue discovery for any book.created event" do
      author = insert(:author, website_url: nil, rss_feed_url: nil)
      book = insert(:book, author: author)

      assert :ok =
               AuthorDiscoveryHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_id: book.id
               })

      refute_enqueued(worker: DiscoverAuthorSourcesJob)
    end

    test "does not enqueue for an already-enriched author either" do
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

    test "ignores unrelated event types" do
      assert :ok =
               AuthorDiscoveryHandler.handle_event(%{
                 event_type: "user.registered",
                 aggregate_id: Ecto.UUID.generate()
               })

      refute_enqueued(worker: DiscoverAuthorSourcesJob)
    end

    test "returns :ok for book.created with a non-existent book id" do
      assert :ok =
               AuthorDiscoveryHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_id: Ecto.UUID.generate()
               })

      refute_enqueued(worker: DiscoverAuthorSourcesJob)
    end
  end
end
