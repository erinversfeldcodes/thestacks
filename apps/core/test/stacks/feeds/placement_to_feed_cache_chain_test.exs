defmodule Stacks.Feeds.PlacementToFeedCacheChainTest do
  @moduledoc """
  End-to-end guarantee for placement → SubscriberWorker →
  PlacementHandler → RegenerateFeedJob → `op.feed_cache` row. Every link
  had its own green test while the chain had never produced a single row
  in any environment — each unit test stopped at its own seam. This one
  drains both Oban queues and asserts the ROW, so any future seam break
  (queue rename, handler unregistered, job arg shape) fails here.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Events
  alias Stacks.Feeds.FeedCacheEntry

  defp drain_chain do
    events = Oban.drain_queue(queue: :events, with_recursion: true)
    default = Oban.drain_queue(queue: :default, with_recursion: true)
    {events, default}
  end

  defp setup_shelf do
    user = insert(:user, display_name: "Erin", profile_visibility: "platform")
    bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
    book = insert(:book, title: "The Name of the Rose")
    placement = insert(:placement, bookshelf: bookshelf, book: book, visibility: "platform")

    %{user: user, bookshelf: bookshelf, book: book, placement: placement}
  end

  defp emit_created(placement, bookshelf_name, visibility) do
    Events.emit(%{
      event_type: "placement.created",
      aggregate_type: "placement",
      aggregate_id: placement.id,
      payload: %{
        book_id: placement.book_id,
        bookshelf: bookshelf_name,
        visibility_tier: visibility
      }
    })
  end

  describe "emitting placement.created reaches op.feed_cache" do
    test "a placement that announces itself ends up in the feed cache" do
      %{bookshelf: bookshelf, placement: placement} = setup_shelf()

      assert Repo.all(FeedCacheEntry) == [],
             "precondition: the cache must start empty or this proves nothing"

      assert {:ok, _} = emit_created(placement, "library", "platform")
      drain_chain()

      rows = Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id)

      assert [row] = rows,
             "the chain did not reach op.feed_cache — emit → dispatch → handler → job is broken"

      assert row.atom_xml =~ "The Name of the Rose",
             "a cache row was written but does not contain the placed book"
    end

    test "a placement written without an event produces nothing" do
      %{bookshelf: bookshelf} = setup_shelf()

      drain_chain()

      assert Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id) == [],
             "a feed appeared without an event — then the chain is not event-driven " <>
               "and this test cannot distinguish the fixed state from the broken one"
    end

    test "many placements on one bookshelf still yield exactly one cache row" do
      %{bookshelf: bookshelf, user: user} = setup_shelf()

      for i <- 1..10 do
        book = insert(:book, title: "Extra Book #{i}")
        p = insert(:placement, bookshelf: bookshelf, book: book, visibility: "platform")
        assert {:ok, _} = emit_created(p, "library", "platform")
      end

      drain_chain()

      rows = Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id)
      assert length(rows) == 1, "expected one cache row per bookshelf, got #{length(rows)}"

      [row] = rows
      assert row.atom_xml =~ "Extra Book 10"
      refute is_nil(user.id)
    end

    test "an owner-visibility bookshelf gets no cache row even when it emits" do
      user = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      book = insert(:book, title: "Private Book")
      placement = insert(:placement, bookshelf: bookshelf, book: book, visibility: "owner")

      assert {:ok, _} = emit_created(placement, "library", "owner")
      drain_chain()

      assert Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id) == [],
             "a private bookshelf must never be published as a feed"
    end
  end
end
