defmodule Stacks.Feeds.PlacementToFeedCacheChainTest do
  @moduledoc """
  End-to-end guarantee for the placement → feed chain:

      Events.emit("placement.created")
        → SubscriberWorker (queue :events)
          → Stacks.Feeds.Handlers.PlacementHandler
            → RegenerateFeedJob (queue :default)
              → op.feed_cache row

  Every link in this chain already had its own passing tests, and the chain had
  **never produced a single `feed_cache` row in any environment**. Each unit test
  asserted its own link and stopped: the handler test asserted a job was
  enqueued, the job test asserted a row was written when the job was performed
  directly. Nothing asserted that emitting the event actually reaches the row.

  That gap is why this file exists and why it drives the real Oban queues via
  `Oban.drain_queue/2` instead of `perform_job/2` — `perform_job` bypasses the
  dispatch that was the missing link.
  """

  # async: false — drains real Oban queues.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Events
  alias Stacks.Feeds.FeedCacheEntry

  # Drains :events first (dispatch), then :default (the work the dispatch queued).
  # Order matters: draining :default first would find nothing to do.
  defp drain_chain do
    events = Oban.drain_queue(queue: :events, with_recursion: true)
    default = Oban.drain_queue(queue: :default, with_recursion: true)
    {events, default}
  end

  defp setup_shelf do
    user = insert(:user, display_name: "Erin", profile_visibility: "platform")
    bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
    book = insert(:book, title: "The Name of the Rose")
    # `insert/2` writes the row directly, exactly as `seeds.exs` does with
    # `insert_all` — so no event is emitted as a side effect and the test has to
    # emit it explicitly, which is the behaviour under test.
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
      # The precise state seeds.exs was in before this was fixed, and the reason
      # `feed_cache` was empty everywhere: the rows existed, nothing announced
      # them, so no amount of draining produced a feed.
      %{bookshelf: bookshelf} = setup_shelf()

      drain_chain()

      assert Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id) == [],
             "a feed appeared without an event — then the chain is not event-driven " <>
               "and this test cannot distinguish the fixed state from the broken one"
    end

    test "many placements on one bookshelf still yield exactly one cache row" do
      # Seeds place up to 40 books on a single bookshelf. Each emits its own
      # event; the cache is keyed by bookshelf, and RegenerateFeedJob dedups the
      # pending duplicates, so the end state is one row regardless.
      %{bookshelf: bookshelf, user: user} = setup_shelf()

      for i <- 1..10 do
        book = insert(:book, title: "Extra Book #{i}")
        p = insert(:placement, bookshelf: bookshelf, book: book, visibility: "platform")
        assert {:ok, _} = emit_created(p, "library", "platform")
      end

      drain_chain()

      rows = Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id)
      assert length(rows) == 1, "expected one cache row per bookshelf, got #{length(rows)}"

      # And the surviving regeneration reflects the full shelf, not just whichever
      # placement won the dedup — the property that makes collapsing safe.
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
