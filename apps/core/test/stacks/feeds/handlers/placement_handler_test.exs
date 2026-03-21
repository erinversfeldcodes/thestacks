defmodule Stacks.Feeds.Handlers.PlacementHandlerTest do
  @moduledoc "Tests for Stacks.Feeds.Handlers.PlacementHandler."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Feeds.Handlers.PlacementHandler
  alias Stacks.Workers.RegenerateFeedJob

  # ---------------------------------------------------------------------------
  # placement.created
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # placement.moved
  # ---------------------------------------------------------------------------

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

      # Only one job should be enqueued, not two
      jobs =
        all_enqueued(worker: RegenerateFeedJob)
        |> Enum.filter(&(&1.args["bookshelf_name"] == "library"))

      assert length(jobs) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # placement.removed
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # catch-all
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # lookup_user_id edge case
  # ---------------------------------------------------------------------------

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
end
