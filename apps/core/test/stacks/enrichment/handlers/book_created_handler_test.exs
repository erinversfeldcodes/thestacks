defmodule Stacks.Enrichment.Handlers.BookCreatedHandlerTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Enrichment.Handlers.BookCreatedHandler
  alias Stacks.Workers.DiscoverAuthorSourcesJob
  alias Stacks.Workers.TriggerPriceScrapeJob

  describe "handle_event/1" do
    test "enqueues TriggerPriceScrapeJob keyed on the ISBN alone" do
      book_id = Ecto.UUID.generate()

      event = %{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: book_id,
        payload: %{"isbn" => "9780743273565", "title" => "The Great Gatsby"}
      }

      assert :ok = BookCreatedHandler.handle_event(event)

      # No `book_id`: a price belongs to an edition, and the ISBN is the edition's
      # natural key. Passing the work would name something with potentially many
      # ISBNs, which cannot say which edition was priced — so the job resolves the
      # edition from the ISBN instead.
      assert_enqueued(worker: TriggerPriceScrapeJob, args: %{isbn: "9780743273565"})
    end

    test "skips enqueue when no ISBN in payload" do
      event = %{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{"title" => "Unknown Book"}
      }

      assert :ok = BookCreatedHandler.handle_event(event)
      refute_enqueued(worker: TriggerPriceScrapeJob)
    end

    test "handles atom-keyed payload" do
      book_id = Ecto.UUID.generate()

      event = %{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: book_id,
        payload: %{isbn: "9780743273565"}
      }

      assert :ok = BookCreatedHandler.handle_event(event)
      assert_enqueued(worker: TriggerPriceScrapeJob)
    end

    test "ignores unrelated events" do
      event = %{
        event_type: "user.registered",
        aggregate_type: "user",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{}
      }

      assert :ok = BookCreatedHandler.handle_event(event)
      refute_enqueued(worker: TriggerPriceScrapeJob)
    end

    test "catch-all clause handles events without matching structure" do
      assert :ok = BookCreatedHandler.handle_event(%{event_type: "something.else"})
      refute_enqueued(worker: TriggerPriceScrapeJob)
    end
  end

  describe "author-source discovery" do
    test "enqueues discovery for authors still missing sources" do
      # `discovered_sources` has never held a row: the nightly batch was the only thing
      # that ran it, and it *creates* rather than refreshes, so a cron entry that may
      # not fire means the feature has never existed.
      author = insert(:author, website_url: nil, rss_feed_url: nil)

      assert :ok =
               BookCreatedHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_type: "book",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{"isbn" => "9780743273565"}
               })

      assert_enqueued(
        worker: DiscoverAuthorSourcesJob,
        args: %{author_id: author.id}
      )
    end

    test "trickles rather than bursting" do
      # A per-book enqueue of *every* author is what the nightly batch replaced, having
      # exhausted Brave's free tier within hours. Work should arrive in proportion to
      # catalogue growth, not all at once.
      Enum.each(1..10, fn _ -> insert(:author, website_url: nil, rss_feed_url: nil) end)

      assert :ok =
               BookCreatedHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_type: "book",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{"isbn" => "9780743273565"}
               })

      enqueued = all_enqueued(worker: DiscoverAuthorSourcesJob)

      assert length(enqueued) == 2,
             "expected a small trickle, got #{length(enqueued)}"
    end

    test "does not re-enqueue the same author within the day" do
      author = insert(:author, website_url: nil, rss_feed_url: nil)

      event = %{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{"isbn" => "9780743273565"}
      }

      Enum.each(1..4, fn _ -> BookCreatedHandler.handle_event(event) end)

      by_author =
        all_enqueued(worker: DiscoverAuthorSourcesJob)
        |> Enum.filter(&(&1.args["author_id"] == author.id))

      assert length(by_author) == 1
    end

    test "skips an author that already has sources" do
      insert(:author,
        website_url: "https://example.test",
        rss_feed_url: "https://example.test/feed"
      )

      assert :ok =
               BookCreatedHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_type: "book",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{"isbn" => "9780743273565"}
               })

      refute_enqueued(worker: DiscoverAuthorSourcesJob)
    end
  end
end
