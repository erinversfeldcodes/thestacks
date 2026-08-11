defmodule Stacks.Feeds.Handlers.PlacementHandlerTest do
  @moduledoc "Tests for Stacks.Feeds.Handlers.PlacementHandler."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Feeds.FeedCacheEntry
  alias Stacks.Feeds.Handlers.PlacementHandler
  alias Stacks.Workers.RegenerateFeedJob

  defp cached_etag(bookshelf_id) do
    Repo.one(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf_id, select: fc.etag)
  end

  describe "handle_event/1 — placement.created" do
    test "extracts bookshelf name and enqueues RegenerateFeedJob (string keys)" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.created",
        aggregate_id: placement.id,
        payload: %{"bookshelf" => "library"}
      }

      assert :ok = PlacementHandler.handle_event(event)

      assert_enqueued(
        worker: RegenerateFeedJob,
        args: %{user_id: user.id, bookshelf_name: "library"}
      )
    end

    test "stands down for goodreads_import-sourced placements (US-1.1.9 coalescing)" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.created",
        aggregate_id: placement.id,
        payload: %{"bookshelf" => "library", "source" => "goodreads_import"}
      }

      assert :ok = PlacementHandler.handle_event(event)

      refute_enqueued(worker: RegenerateFeedJob)
    end

    test "a manual source still regenerates" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.created",
        aggregate_id: placement.id,
        payload: %{"bookshelf" => "library", "source" => "manual"}
      }

      assert :ok = PlacementHandler.handle_event(event)
      assert_enqueued(worker: RegenerateFeedJob)
    end

    test "extracts bookshelf name with atom keys in payload" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "antilibrary")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.created",
        aggregate_id: placement.id,
        payload: %{bookshelf: "antilibrary"}
      }

      assert :ok = PlacementHandler.handle_event(event)

      assert_enqueued(
        worker: RegenerateFeedJob,
        args: %{user_id: user.id, bookshelf_name: "antilibrary"}
      )
    end
  end

  describe "handle_event/1 — placement.moved" do
    test "enqueues jobs for both source and destination bookshelves (string keys)" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.moved",
        aggregate_id: placement.id,
        payload: %{"to_bookshelf" => "library", "from_bookshelf" => "antilibrary"}
      }

      assert :ok = PlacementHandler.handle_event(event)

      assert_enqueued(
        worker: RegenerateFeedJob,
        args: %{user_id: user.id, bookshelf_name: "library"}
      )

      assert_enqueued(
        worker: RegenerateFeedJob,
        args: %{user_id: user.id, bookshelf_name: "antilibrary"}
      )
    end

    test "enqueues jobs for both bookshelves with atom keys" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "wishlist")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.moved",
        aggregate_id: placement.id,
        payload: %{to_bookshelf: "wishlist", from_bookshelf: "reading_pile"}
      }

      assert :ok = PlacementHandler.handle_event(event)

      assert_enqueued(
        worker: RegenerateFeedJob,
        args: %{user_id: user.id, bookshelf_name: "wishlist"}
      )

      assert_enqueued(
        worker: RegenerateFeedJob,
        args: %{user_id: user.id, bookshelf_name: "reading_pile"}
      )
    end

    test "deduplicates when source and destination are the same" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.moved",
        aggregate_id: placement.id,
        payload: %{"to_bookshelf" => "library", "from_bookshelf" => "library"}
      }

      assert :ok = PlacementHandler.handle_event(event)

      jobs =
        all_enqueued(worker: RegenerateFeedJob)
        |> Enum.filter(&(&1.args["bookshelf_name"] == "library"))

      assert length(jobs) == 1
    end
  end

  describe "handle_event/1 — placement.removed" do
    test "handles nil bookshelf name gracefully (no job enqueued)" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.removed",
        aggregate_id: placement.id,
        payload: %{}
      }

      assert :ok = PlacementHandler.handle_event(event)
      refute_enqueued(worker: RegenerateFeedJob)
    end
  end

  describe "handle_event/1 — catch-all" do
    test "returns :ok for unrelated events" do
      event = %{
        event_type: "book.created",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{}
      }

      assert :ok = PlacementHandler.handle_event(event)
      refute_enqueued(worker: RegenerateFeedJob)
    end

    test "returns :ok for events with no event_type key" do
      assert :ok = PlacementHandler.handle_event(%{something: "else"})
    end
  end

  describe "handle_event/1 — missing placement" do
    test "returns :ok when aggregate_id does not match a placement" do
      event = %{
        event_type: "placement.created",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{"bookshelf" => "library"}
      }

      assert :ok = PlacementHandler.handle_event(event)
      refute_enqueued(worker: RegenerateFeedJob)
    end
  end

  describe "handle_event/1 → drain → feed_cache written" do
    test "a placement.created on a platform shelf leaves the cache row written" do
      user = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      event = %{
        event_type: "placement.created",
        aggregate_id: placement.id,
        payload: %{"bookshelf" => "library"}
      }

      assert :ok = PlacementHandler.handle_event(event)
      Oban.drain_queue(queue: :default)

      row = Repo.get_by(FeedCacheEntry, bookshelf_id: bookshelf.id)
      assert row, "draining the enqueued RegenerateFeedJob must write the cache row"
      assert row.atom_xml =~ "The Secret History"
    end

    test "placement.moved rewrites BOTH source and destination cache rows" do
      user = insert(:user, profile_visibility: "platform")
      src = insert(:bookshelf, user: user, name: "antilibrary", visibility: "platform")
      dst = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "Moved Book")
      placement = insert(:placement, bookshelf: dst, book: book)

      event = %{
        event_type: "placement.moved",
        aggregate_id: placement.id,
        payload: %{"to_bookshelf" => "library", "from_bookshelf" => "antilibrary"}
      }

      assert :ok = PlacementHandler.handle_event(event)
      Oban.drain_queue(queue: :default)

      assert cached_etag(src.id), "source bookshelf feed cache must be (re)written"
      assert cached_etag(dst.id), "destination bookshelf feed cache must be (re)written"
    end
  end
end
