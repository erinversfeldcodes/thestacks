defmodule Stacks.ShelvingTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Ecto.Adapters.SQL.Sandbox
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  # Places `book` on `user`'s named bookshelf with a real shelf (shelf_id is NOT
  # NULL). `attrs` may carry :listing_status / :removed_at. Used by the #285
  # discovery-helper tests below.
  defp place_on(user, book, shelf_name, attrs \\ []) do
    bookshelf = insert(:bookshelf, user: user, name: shelf_name)
    shelf = insert(:shelf, bookshelf: bookshelf)
    insert(:placement, [book: book, bookshelf: bookshelf, shelf: shelf] ++ attrs)
  end

  defp setup_user_bookshelf_book(_ctx) do
    user = insert(:user)
    bookshelf = insert(:bookshelf, user: user, name: "library")
    book = insert(:book)
    placement = insert(:placement, bookshelf: bookshelf, book: book)
    %{user: user, bookshelf: bookshelf, book: book, placement: placement}
  end

  describe "get_bookshelf_books/2" do
    setup :setup_user_bookshelf_book

    test "returns active placements on bookshelf", %{user: user, placement: placement} do
      placements = Shelving.get_bookshelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      assert placement.id in ids
    end

    test "excludes removed placements", %{user: user, placement: placement} do
      Shelving.remove_book(placement.id, user.id)
      placements = Shelving.get_bookshelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      refute placement.id in ids
    end

    test "returns empty list for bookshelf with no books", %{user: user} do
      assert [] == Shelving.get_bookshelf_books(user.id, "wishlist")
    end
  end

  describe "place_book/3" do
    test "creates a placement and returns {:ok, placement}" do
      user = insert(:user)
      book = insert(:book)
      assert {:ok, placement} = Shelving.place_book(user.id, book.id, "library")
      assert placement.book_id == book.id
    end

    test "creates the bookshelf if it does not exist" do
      user = insert(:user)
      book = insert(:book)
      assert {:ok, _placement} = Shelving.place_book(user.id, book.id, "wishlist")
    end

    test "emits placement.created event" do
      user = insert(:user)
      book = insert(:book)
      before_count = event_count("placement.created")

      Shelving.place_book(user.id, book.id, "library")

      assert event_count("placement.created") == before_count + 1
    end

    test "placement.created payload includes the book's visibility_tier" do
      user = insert(:user)
      book = insert(:book, visibility_tier: "age_gated")

      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")

      latest =
        from(e in "event_log",
          prefix: "op",
          where: e.event_type == "placement.created",
          order_by: [desc: e.occurred_at],
          limit: 1,
          select: %{aggregate_id: e.aggregate_id, payload: e.payload}
        )
        |> Repo.one()

      {:ok, latest_aggregate_id} = Ecto.UUID.load(latest.aggregate_id)
      assert latest_aggregate_id == placement.id
      assert latest.payload["visibility_tier"] == "age_gated"
      assert latest.payload["book_id"] == book.id
      assert latest.payload["bookshelf"] == "library"
    end

    test "returns changeset error when book does not exist" do
      user = insert(:user)
      nonexistent_book_id = Ecto.UUID.generate()
      assert {:error, changeset} = Shelving.place_book(user.id, nonexistent_book_id, "library")
      assert %{book_id: [_]} = errors_on(changeset)
    end

    test "returns changeset error when book already on the same shelf" do
      user = insert(:user)
      book = insert(:book)
      assert {:ok, _} = Shelving.place_book(user.id, book.id, "library")
      assert {:error, changeset} = Shelving.place_book(user.id, book.id, "library")
      assert %{book_id: ["book is already on this bookshelf"]} = errors_on(changeset)
    end
  end

  describe "move_book/3" do
    setup :setup_user_bookshelf_book

    test "moves placement to new bookshelf and writes history", %{
      user: user,
      bookshelf: bookshelf,
      placement: placement
    } do
      assert {:ok, %{placement: _moved, history: history}} =
               Shelving.move_book(placement.id, user.id, "wishlist")

      moved_placement = Repo.get!(Placement, placement.id) |> Repo.preload(:bookshelf)
      assert moved_placement.bookshelf.name == "wishlist"

      assert history.book_id == placement.book_id
      assert history.from_bookshelf == bookshelf.id
    end

    test "creates history record in PlacementHistory table", %{
      user: user,
      bookshelf: bookshelf,
      placement: placement
    } do
      Shelving.move_book(placement.id, user.id, "wishlist")

      history =
        PlacementHistory
        |> Repo.get_by(book_id: placement.book_id, from_bookshelf: bookshelf.id)

      assert history != nil
    end

    test "emits placement.moved event", %{user: user, placement: placement} do
      before_count = event_count("placement.moved")

      Shelving.move_book(placement.id, user.id, "wishlist")

      assert event_count("placement.moved") == before_count + 1
    end

    test "returns :unauthorized when user does not own the placement", %{placement: placement} do
      other_user = insert(:user)

      assert {:error, :unauthorized} =
               Shelving.move_book(placement.id, other_user.id, "wishlist")
    end

    test "returns :not_found for a missing placement", %{user: user} do
      assert {:error, :not_found} = Shelving.move_book(Ecto.UUID.generate(), user.id, "wishlist")
    end

    test "history row records to_bookshelf as the destination bookshelf id", %{
      user: user,
      bookshelf: bookshelf,
      placement: placement
    } do
      assert {:ok, %{history: history}} = Shelving.move_book(placement.id, user.id, "wishlist")

      wishlist = Repo.get_by!(Bookshelf, user_id: user.id, name: "wishlist")
      assert history.from_bookshelf == bookshelf.id
      assert history.to_bookshelf == wishlist.id
    end

    test "writes an audit-log entry for the move (:audit Multi step)", %{
      user: user,
      placement: placement
    } do
      before_count = audit_count("placement.moved")

      assert {:ok, _} = Shelving.move_book(placement.id, user.id, "wishlist")

      assert audit_count("placement.moved") == before_count + 1

      row = latest_audit_row("placement.moved")
      assert row.rt == "placement"
      assert row.rid == Ecto.UUID.dump!(placement.id)
      assert row.uid == Ecto.UUID.dump!(user.id)
    end

    test "emits placement.moved and ONLY that (no created/removed delta)", %{
      user: user,
      placement: placement
    } do
      created_before = event_count("placement.created")
      removed_before = event_count("placement.removed")

      assert {:ok, _} = Shelving.move_book(placement.id, user.id, "wishlist")

      assert event_count("placement.created") == created_before
      assert event_count("placement.removed") == removed_before
    end
  end

  describe "move_book/3 — same-bookshelf move is a no-op success (Fix B)" do
    test "returns {:ok, placement} and writes no history, event, or audit row" do
      user = insert(:user)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")

      events_before = event_count("placement.moved")
      audits_before = audit_count("placement.moved")
      history_before = Repo.aggregate(PlacementHistory, :count)

      assert {:ok, %{placement: returned}} = Shelving.move_book(placement.id, user.id, "library")
      assert returned.id == placement.id

      assert event_count("placement.moved") == events_before
      assert audit_count("placement.moved") == audits_before
      assert Repo.aggregate(PlacementHistory, :count) == history_before
    end

    test "does not reset a non-default shelf assignment to position 0" do
      user = insert(:user)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")
      bookshelf = Repo.get_by!(Bookshelf, user_id: user.id, name: "library")

      # Move the placement onto a second (non-position-0) shelf of the SAME
      # bookshelf, then perform a same-bookshelf move: the no-op must NOT yank it
      # back to the position-0 default shelf (which the old Multi path did).
      {:ok, shelf2} = Shelving.create_shelf(bookshelf.id, user.id)
      {:ok, on_shelf2} = Shelving.move_placement_to_shelf(placement.id, shelf2.id, user.id)
      assert on_shelf2.shelf_id == shelf2.id

      assert {:ok, %{placement: _}} = Shelving.move_book(placement.id, user.id, "library")

      reloaded = Repo.get!(Placement, placement.id)
      assert reloaded.shelf_id == shelf2.id
    end
  end

  describe "move_book/3 — atomicity / rollback" do
    test "a step failure rolls back the placement update, history, event, and audit" do
      # Force a deterministic mid-Multi failure: the placement UPDATE hits the
      # partial unique index (one active placement per book+bookshelf) because the
      # same book is already active on the destination. The whole transaction must
      # roll back — the source placement stays put and nothing else is written.
      user = insert(:user)
      book = insert(:book)
      {:ok, source} = Shelving.place_book(user.id, book.id, "wishlist")
      {:ok, _blocker} = Shelving.place_book(user.id, book.id, "antilibrary")

      events_before = event_count("placement.moved")
      audits_before = audit_count("placement.moved")
      history_before = Repo.aggregate(PlacementHistory, :count)

      assert {:error, :placement, %Ecto.Changeset{}, _changes} =
               Shelving.move_book(source.id, user.id, "antilibrary")

      unmoved = Repo.get!(Placement, source.id) |> Repo.preload(:bookshelf)
      assert unmoved.bookshelf.name == "wishlist"
      assert event_count("placement.moved") == events_before
      assert audit_count("placement.moved") == audits_before
      assert Repo.aggregate(PlacementHistory, :count) == history_before
    end
  end

  describe "move_book/3 — shelf reassignment and browse visibility" do
    test "the moved placement's shelf belongs to the destination bookshelf" do
      user = insert(:user)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "wishlist")

      assert {:ok, _} = Shelving.move_book(placement.id, user.id, "antilibrary")

      moved = Repo.get!(Placement, placement.id) |> Repo.preload(shelf: :bookshelf)
      assert moved.shelf != nil
      assert moved.shelf.bookshelf.name == "antilibrary"
      assert moved.shelf.bookshelf.user_id == user.id
    end

    test "get_bookshelf_shelves lists the book on the TARGET and not the SOURCE after a move" do
      user = insert(:user)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "wishlist")

      # Sanity: the book starts on the source browse.
      assert book.id in browse_book_ids(user.id, "wishlist")

      assert {:ok, _} = Shelving.move_book(placement.id, user.id, "antilibrary")

      assert book.id in browse_book_ids(user.id, "antilibrary")
      refute book.id in browse_book_ids(user.id, "wishlist")
    end
  end

  describe "reading pile 50-item limit (#276)" do
    test "place_book/3 allows the 50th reading_pile placement" do
      user = insert(:user)
      fill_reading_pile(user, 49)
      book = insert(:book)

      assert {:ok, placement} = Shelving.place_book(user.id, book.id, "reading_pile")
      assert placement.book_id == book.id
      assert active_pile_count(user.id) == 50
    end

    test "place_book/3 rejects the 51st reading_pile placement" do
      user = insert(:user)
      fill_reading_pile(user, 50)
      book = insert(:book)

      assert {:error, :reading_pile_full} = Shelving.place_book(user.id, book.id, "reading_pile")
      assert active_pile_count(user.id) == 50
    end

    test "move_book/3 allows a move that makes exactly 50" do
      user = insert(:user)
      fill_reading_pile(user, 49)
      library = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: library, book: insert(:book))

      assert {:ok, %{placement: _}} = Shelving.move_book(placement.id, user.id, "reading_pile")
      assert active_pile_count(user.id) == 50
    end

    test "move_book/3 rejects a move that would make 51" do
      user = insert(:user)
      fill_reading_pile(user, 50)
      library = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: library, book: insert(:book))

      assert {:error, :reading_pile_capacity, :reading_pile_full, _} =
               Shelving.move_book(placement.id, user.id, "reading_pile")

      assert active_pile_count(user.id) == 50
    end

    test "rejected place_book writes no placement, event, or audit row" do
      user = insert(:user)
      fill_reading_pile(user, 50)
      book = insert(:book)

      events_before = event_count("placement.created")
      audits_before = audit_count("placement.created")

      assert {:error, :reading_pile_full} = Shelving.place_book(user.id, book.id, "reading_pile")

      assert active_pile_count(user.id) == 50
      assert event_count("placement.created") == events_before
      assert audit_count("placement.created") == audits_before
    end

    test "rejected move_book leaves the placement and writes no history, event, or audit row" do
      user = insert(:user)
      fill_reading_pile(user, 50)
      library = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: library, book: insert(:book))

      events_before = event_count("placement.moved")
      audits_before = audit_count("placement.moved")
      history_before = Repo.aggregate(PlacementHistory, :count)

      assert {:error, :reading_pile_capacity, :reading_pile_full, _} =
               Shelving.move_book(placement.id, user.id, "reading_pile")

      unmoved = Repo.get!(Placement, placement.id)
      assert unmoved.bookshelf_id == library.id
      assert event_count("placement.moved") == events_before
      assert audit_count("placement.moved") == audits_before
      assert Repo.aggregate(PlacementHistory, :count) == history_before
    end

    test "the limit applies to reading_pile only" do
      user = insert(:user)
      library = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: library)

      for _ <- 1..50 do
        insert(:placement, bookshelf: library, shelf: shelf, book: insert(:book))
      end

      book = insert(:book)
      assert {:ok, _} = Shelving.place_book(user.id, book.id, "library")
    end

    test "grandfathered over-limit piles keep their books and can still move books out" do
      user = insert(:user)
      pile = fill_reading_pile(user, 55)
      book = insert(:book)

      # No new placement while over the limit...
      assert {:error, :reading_pile_full} = Shelving.place_book(user.id, book.id, "reading_pile")

      # ...but every existing book is intact (no data loss)...
      assert active_pile_count(user.id) == 55

      # ...and moving a book OUT of the pile still works.
      out_placement =
        Placement
        |> where([p], p.bookshelf_id == ^pile.id and is_nil(p.removed_at))
        |> limit(1)
        |> Repo.one!()

      assert {:ok, %{placement: _}} = Shelving.move_book(out_placement.id, user.id, "library")
      assert active_pile_count(user.id) == 54
    end

    test "moving within a full reading pile is not blocked" do
      user = insert(:user)
      pile = fill_reading_pile(user, 50)

      placement =
        Placement
        |> where([p], p.bookshelf_id == ^pile.id and is_nil(p.removed_at))
        |> limit(1)
        |> Repo.one!()

      # A same-bookshelf "move" does not add a book, so the cap must not fire.
      assert {:ok, %{placement: _}} = Shelving.move_book(placement.id, user.id, "reading_pile")
      assert active_pile_count(user.id) == 50
    end

    test "two concurrent placements cannot exceed the cap" do
      # NOTE: under the SQL sandbox both tasks share the test's DB connection,
      # so their transactions serialize here regardless of the FOR UPDATE lock.
      # This test proves the end-to-end invariant (never > 50); the
      # cross-connection race itself is closed by the documented
      # SELECT ... FOR UPDATE on the bookshelf row in the capacity check.
      user = insert(:user)
      fill_reading_pile(user, 49)
      owner = self()

      results =
        [insert(:book), insert(:book)]
        |> Enum.map(fn book ->
          Task.async(fn ->
            Sandbox.allow(Repo, owner, self())
            Shelving.place_book(user.id, book.id, "reading_pile")
          end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :reading_pile_full}, &1)) == 1
      assert active_pile_count(user.id) == 50
    end
  end

  describe "remove_book/2" do
    setup :setup_user_bookshelf_book

    test "sets removed_at on the placement", %{user: user, placement: placement} do
      assert {:ok, removed} = Shelving.remove_book(placement.id, user.id)
      assert removed.removed_at != nil
    end

    test "returns :not_found for a missing placement", %{user: user} do
      assert {:error, :not_found} = Shelving.remove_book(Ecto.UUID.generate(), user.id)
    end

    test "placement no longer appears in bookshelf listing after removal", %{
      user: user,
      placement: placement
    } do
      Shelving.remove_book(placement.id, user.id)
      placements = Shelving.get_bookshelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      refute placement.id in ids
    end

    test "emits placement.removed event", %{user: user, placement: placement} do
      before_count = event_count("placement.removed")

      Shelving.remove_book(placement.id, user.id)

      assert event_count("placement.removed") == before_count + 1
    end

    test "writes an audit-log entry for the removal (:audit Multi step)", %{
      user: user,
      placement: placement
    } do
      before_count = audit_count("placement.removed")

      assert {:ok, _} = Shelving.remove_book(placement.id, user.id)

      assert audit_count("placement.removed") == before_count + 1

      row = latest_audit_row("placement.removed")
      assert row.rt == "placement"
      assert row.rid == Ecto.UUID.dump!(placement.id)
      assert row.uid == Ecto.UUID.dump!(user.id)
    end

    test "emits placement.removed and ONLY that (no created/moved delta)", %{
      user: user,
      placement: placement
    } do
      created_before = event_count("placement.created")
      moved_before = event_count("placement.moved")

      assert {:ok, _} = Shelving.remove_book(placement.id, user.id)

      assert event_count("placement.created") == created_before
      assert event_count("placement.moved") == moved_before
    end

    test "the underlying op.books record survives the soft-delete", %{
      user: user,
      book: book,
      placement: placement
    } do
      assert {:ok, _} = Shelving.remove_book(placement.id, user.id)

      # Placement is soft-deleted (removed_at set, row present)...
      soft_deleted = Repo.get!(Placement, placement.id)
      assert soft_deleted.removed_at != nil

      # ...but the book row is untouched (remove is not a hard delete of the book).
      assert Repo.get(Stacks.Books.Book, book.id) != nil
    end
  end

  describe "reread_book/2" do
    setup do
      user = insert(:user)
      # Use a non-library bookshelf so reread can create a fresh library placement
      bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)
      %{user: user, bookshelf: bookshelf, book: book, placement: placement}
    end

    test "creates a new placement on the library bookshelf", %{user: user, placement: placement} do
      assert {:ok, new_placement} = Shelving.reread_book(placement.id, user.id)
      assert new_placement.book_id == placement.book_id

      library_bookshelf = Repo.get_by(Bookshelf, user_id: user.id, name: "library")
      assert new_placement.bookshelf_id == library_bookshelf.id
    end

    test "new placement is separate from the original", %{user: user, placement: placement} do
      assert {:ok, new_placement} = Shelving.reread_book(placement.id, user.id)
      refute new_placement.id == placement.id
    end

    test "writes a PlacementHistory record from the original bookshelf to library", %{
      user: user,
      bookshelf: bookshelf,
      placement: placement
    } do
      assert {:ok, _new_placement} = Shelving.reread_book(placement.id, user.id)

      library_bookshelf = Repo.get_by(Bookshelf, user_id: user.id, name: "library")

      history =
        Repo.get_by(PlacementHistory,
          book_id: placement.book_id,
          from_bookshelf: bookshelf.id,
          to_bookshelf: library_bookshelf.id
        )

      assert history != nil
    end

    test "emits placement.reread event", %{user: user, placement: placement} do
      before_count = event_count("placement.reread")

      Shelving.reread_book(placement.id, user.id)

      assert event_count("placement.reread") == before_count + 1
    end

    test "writes an audit-log entry for the re-read (:audit Multi step)", %{
      user: user,
      placement: placement
    } do
      before_count = audit_count("placement.reread")

      assert {:ok, new_placement} = Shelving.reread_book(placement.id, user.id)

      assert audit_count("placement.reread") == before_count + 1

      # The :audit step logs the NEW library placement do_reread_book/2 creates
      # (resource_id: p.id, where p is the inserted placement), not the original.
      row = latest_audit_row("placement.reread")
      assert row.rt == "placement"
      assert row.rid == Ecto.UUID.dump!(new_placement.id)
      assert row.uid == Ecto.UUID.dump!(user.id)
    end

    test "emits placement.reread and ONLY that (no created/moved/removed delta)", %{
      user: user,
      placement: placement
    } do
      created_before = event_count("placement.created")
      moved_before = event_count("placement.moved")
      removed_before = event_count("placement.removed")

      assert {:ok, _} = Shelving.reread_book(placement.id, user.id)

      assert event_count("placement.created") == created_before
      assert event_count("placement.moved") == moved_before
      assert event_count("placement.removed") == removed_before
    end

    test "returns :unauthorized when the user does not own the placement", %{placement: placement} do
      other_user = insert(:user)
      assert {:error, :unauthorized} = Shelving.reread_book(placement.id, other_user.id)
    end

    test "returns :not_found for a missing placement", %{user: user} do
      assert {:error, :not_found} = Shelving.reread_book(Ecto.UUID.generate(), user.id)
    end
  end

  describe "abandon_book/2" do
    setup :setup_user_bookshelf_book

    test "moves placement to looking_for_home bookshelf", %{user: user, placement: placement} do
      assert {:ok, _result} = Shelving.abandon_book(placement.id, user.id)

      moved = Repo.get!(Placement, placement.id) |> Repo.preload(:bookshelf)
      assert moved.bookshelf.name == "looking_for_home"
    end

    test "returns :unauthorized when user does not own the placement", %{placement: placement} do
      other_user = insert(:user)
      assert {:error, :unauthorized} = Shelving.abandon_book(placement.id, other_user.id)
    end

    test "abandon_book surfaces the book on the looking_for_home browse and off the source" do
      user = insert(:user)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "reading_pile")

      assert {:ok, _} = Shelving.abandon_book(placement.id, user.id)

      assert book.id in browse_book_ids(user.id, "looking_for_home")
      refute book.id in browse_book_ids(user.id, "reading_pile")
    end

    test "a step failure rolls back the abandon (no history, event, or audit, placement unmoved)" do
      # abandon_book delegates to move_book(_, _, "looking_for_home"); force the
      # same deterministic update-step failure via the active-placement unique
      # index (the book is already active on looking_for_home).
      user = insert(:user)
      book = insert(:book)
      {:ok, source} = Shelving.place_book(user.id, book.id, "reading_pile")
      {:ok, _blocker} = Shelving.place_book(user.id, book.id, "looking_for_home")

      events_before = event_count("placement.moved")
      audits_before = audit_count("placement.moved")
      history_before = Repo.aggregate(PlacementHistory, :count)

      assert {:error, :placement, %Ecto.Changeset{}, _changes} =
               Shelving.abandon_book(source.id, user.id)

      unmoved = Repo.get!(Placement, source.id) |> Repo.preload(:bookshelf)
      assert unmoved.bookshelf.name == "reading_pile"
      assert event_count("placement.moved") == events_before
      assert audit_count("placement.moved") == audits_before
      assert Repo.aggregate(PlacementHistory, :count) == history_before
    end
  end

  describe "shelf_changeset/2 — unique (bookshelf_id, position) constraint (Fix A)" do
    test "a duplicate (bookshelf_id, position) insert returns {:error, changeset}, not a raise" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      # First shelf at position 0.
      insert(:shelf, bookshelf: bookshelf, position: 0)

      # A second insert at the same (bookshelf_id, position) must surface the DB
      # partial-unique index as a changeset error. Without the declared
      # unique_constraint, Repo.insert RAISES Ecto.ConstraintError — which is
      # exactly what breaks get_or_create_default_shelf/1's `{:error, _} -> get_by!`
      # race fallback.
      result =
        %Stacks.Shelving.Shelf{}
        |> Shelving.shelf_changeset(%{bookshelf_id: bookshelf.id, position: 0})
        |> Repo.insert()

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert %{bookshelf_id: [_]} = errors_on(changeset)
    end
  end

  describe "remove_book/2 — unauthorized" do
    setup :setup_user_bookshelf_book

    test "returns :unauthorized when user does not own the placement", %{placement: placement} do
      other_user = insert(:user)
      assert {:error, :unauthorized} = Shelving.remove_book(placement.id, other_user.id)
    end
  end

  describe "update_placement_formats/3" do
    setup :setup_user_bookshelf_book

    test "updates the formats list for an owned placement", %{user: user, placement: placement} do
      assert {:ok, updated} =
               Shelving.update_placement_formats(placement.id, user.id, ["hardcover"])

      assert updated.formats == ["hardcover"]
    end

    test "returns :not_found for a missing placement", %{user: user} do
      assert {:error, :not_found} =
               Shelving.update_placement_formats(Ecto.UUID.generate(), user.id, ["hardcover"])
    end

    test "returns :unauthorized when user does not own the placement", %{placement: placement} do
      other_user = insert(:user)

      assert {:error, :unauthorized} =
               Shelving.update_placement_formats(placement.id, other_user.id, ["hardcover"])
    end
  end

  describe "spine_data/1" do
    setup :setup_user_bookshelf_book

    test "returns spine data with wear_level :new for unread placement", %{
      placement: placement
    } do
      data = Shelving.spine_data(placement.id)
      assert data.wear_level == :new
      assert data.move_count == 0
    end

    test "returns nil for unknown placement" do
      assert nil == Shelving.spine_data(Ecto.UUID.generate())
    end

    # compute_wear_level branches (shelving.ex:545-548): move_count 0 → :new,
    # 1-2 → :light, 3-5 → :moderate, 6+ → :heavy. move_count is COUNT(*) of
    # PlacementHistory rows for the placement's book, so we seed that many
    # history rows keyed on the book. Boundary values are asserted exactly so
    # the tests fail if any threshold constant shifts.

    test "wear_level is :light at move_count 1 (lower :light boundary)", %{
      book: book,
      bookshelf: bookshelf,
      placement: placement
    } do
      seed_move_history(book, bookshelf, 1)

      data = Shelving.spine_data(placement.id)
      assert data.move_count == 1
      assert data.wear_level == :light
    end

    test "wear_level is :light at move_count 2 (upper :light boundary)", %{
      book: book,
      bookshelf: bookshelf,
      placement: placement
    } do
      seed_move_history(book, bookshelf, 2)

      data = Shelving.spine_data(placement.id)
      assert data.move_count == 2
      assert data.wear_level == :light
    end

    test "wear_level is :moderate at move_count 3 (lower :moderate boundary)", %{
      book: book,
      bookshelf: bookshelf,
      placement: placement
    } do
      seed_move_history(book, bookshelf, 3)

      data = Shelving.spine_data(placement.id)
      assert data.move_count == 3
      assert data.wear_level == :moderate
    end

    test "wear_level is :moderate at move_count 5 (upper :moderate boundary)", %{
      book: book,
      bookshelf: bookshelf,
      placement: placement
    } do
      seed_move_history(book, bookshelf, 5)

      data = Shelving.spine_data(placement.id)
      assert data.move_count == 5
      assert data.wear_level == :moderate
    end

    test "wear_level is :heavy at move_count 6 (lower :heavy boundary)", %{
      book: book,
      bookshelf: bookshelf,
      placement: placement
    } do
      seed_move_history(book, bookshelf, 6)

      data = Shelving.spine_data(placement.id)
      assert data.move_count == 6
      assert data.wear_level == :heavy
    end
  end

  # Inserts `count` PlacementHistory rows for `book`, using a real bookshelf id
  # for the from_bookshelf/to_bookshelf FKs. move_count is COUNT(*) of these
  # rows for the book, which is what compute_wear_level reads.
  defp seed_move_history(book, bookshelf, count) do
    insert_list(count, :placement_history,
      book_id: book.id,
      from_bookshelf: bookshelf.id,
      to_bookshelf: bookshelf.id
    )
  end

  describe "spine_data/1 — formats from editions" do
    test "returns formats list derived from book editions" do
      book = insert(:book)
      _edition = insert(:book_edition, book: book, format_label: "Paperback", is_primary: true)

      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      data = Shelving.spine_data(placement.id)

      assert is_list(data.formats)
      assert "Paperback" in data.formats
    end

    test "formats list includes all edition format labels" do
      book = insert(:book)
      _primary = insert(:book_edition, book: book, format_label: "Hardcover", is_primary: true)
      _secondary = insert(:book_edition, book: book, format_label: "Ebook", is_primary: false)

      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      data = Shelving.spine_data(placement.id)

      assert length(data.formats) == 2
      assert "Hardcover" in data.formats
      assert "Ebook" in data.formats
    end

    test "page_count comes from the primary edition" do
      book = insert(:book)

      _primary =
        insert(:book_edition,
          book: book,
          format_label: "Hardcover",
          page_count: 450,
          is_primary: true
        )

      _secondary =
        insert(:book_edition,
          book: book,
          format_label: "Ebook",
          page_count: 400,
          is_primary: false
        )

      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      data = Shelving.spine_data(placement.id)

      assert data.page_count == 450
    end

    test "page_count falls back to first edition when no primary" do
      book = insert(:book)

      _only =
        insert(:book_edition,
          book: book,
          format_label: "Paperback",
          page_count: 320,
          is_primary: false
        )

      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      data = Shelving.spine_data(placement.id)

      assert data.page_count == 320
    end

    test "formats is empty list when book has no editions" do
      book = insert(:book)
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      data = Shelving.spine_data(placement.id)

      assert data.formats == []
    end

    test "page_count is nil when book has no editions" do
      book = insert(:book)
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      data = Shelving.spine_data(placement.id)

      assert data.page_count == nil
    end
  end

  describe "update_bookshelf_visibility/3" do
    setup :setup_user_bookshelf_book

    test "owner can update bookshelf visibility" do
      # profile_visibility "platform" so raising the bookshelf to "platform"
      # is within the profile ceiling (US-10.2.1).
      user = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert {:ok, updated} =
               Shelving.update_bookshelf_visibility(bookshelf.id, user.id, "platform")

      assert updated.visibility == "platform"
    end

    test "DB record is updated" do
      user = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      Shelving.update_bookshelf_visibility(bookshelf.id, user.id, "platform")
      reloaded = Repo.get!(Bookshelf, bookshelf.id)
      assert reloaded.visibility == "platform"
    end

    test "rejects visibility that exceeds the profile ceiling (US-10.2.1)" do
      # profile_visibility "owner" is a hard ceiling — the bookshelf cannot be
      # made more visible than the profile.
      user = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert {:error, changeset} =
               Shelving.update_bookshelf_visibility(bookshelf.id, user.id, "platform")

      assert %{visibility: [_]} = errors_on(changeset)
      # Stored value is unchanged.
      assert Repo.get!(Bookshelf, bookshelf.id).visibility == "owner"
    end

    test "returns :unauthorized when user does not own the bookshelf", %{bookshelf: bookshelf} do
      other = insert(:user)

      assert {:error, :unauthorized} =
               Shelving.update_bookshelf_visibility(bookshelf.id, other.id, "platform")
    end

    test "returns :not_found for nonexistent bookshelf id" do
      user = insert(:user)

      assert {:error, :not_found} =
               Shelving.update_bookshelf_visibility(Ecto.UUID.generate(), user.id, "platform")
    end

    test "returns changeset error for invalid visibility value", %{
      user: user,
      bookshelf: bookshelf
    } do
      assert {:error, changeset} =
               Shelving.update_bookshelf_visibility(bookshelf.id, user.id, "secret")

      assert %{visibility: [_]} = errors_on(changeset)
    end
  end

  describe "update_placement_visibility/3" do
    setup do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, visibility: "owner")
      %{user: user, bookshelf: bookshelf, book: book, placement: placement}
    end

    test "owner can set placement visibility within the bookshelf ceiling", %{
      user: user,
      placement: placement
    } do
      # bookshelf is "platform" (rank 1), "platform" placement (rank 1) is valid
      assert {:ok, updated} =
               Shelving.update_placement_visibility(placement.id, user.id, "platform")

      assert updated.visibility == "platform"
    end

    test "DB record is updated", %{user: user, placement: placement} do
      Shelving.update_placement_visibility(placement.id, user.id, "platform")
      reloaded = Repo.get!(Placement, placement.id)
      assert reloaded.visibility == "platform"
    end

    test "rejects visibility less restrictive than bookshelf ceiling", %{user: user} do
      # bookshelf is "owner" (rank 2); placement "platform" (rank 1) violates ceiling
      owner_bookshelf = insert(:bookshelf, user: user, name: "wishlist", visibility: "owner")
      book = insert(:book)
      placement = insert(:placement, bookshelf: owner_bookshelf, book: book, visibility: "owner")

      assert {:error, reason} =
               Shelving.update_placement_visibility(placement.id, user.id, "platform")

      assert is_binary(reason)
    end

    test "returns :unauthorized when user does not own the placement", %{placement: placement} do
      other = insert(:user)

      assert {:error, :unauthorized} =
               Shelving.update_placement_visibility(placement.id, other.id, "owner")
    end

    test "returns :not_found for nonexistent placement id" do
      user = insert(:user)

      assert {:error, :not_found} =
               Shelving.update_placement_visibility(Ecto.UUID.generate(), user.id, "owner")
    end

    test "setting placement to 'owner' always passes ceiling (most restrictive)", %{
      user: user,
      bookshelf: bookshelf
    } do
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, visibility: "platform")
      assert {:ok, updated} = Shelving.update_placement_visibility(placement.id, user.id, "owner")
      assert updated.visibility == "owner"
    end
  end

  # ---------------------------------------------------------------------------
  # Reading Progress Tracking (Issue #148)
  # ---------------------------------------------------------------------------

  describe "update_reading_progress/3" do
    setup :setup_user_bookshelf_book

    test "transitions status from to_read to reading", %{user: user, placement: placement} do
      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading"
               })

      assert updated.reading_status == "reading"
    end

    test "transitions status from reading to completed", %{user: user, placement: placement} do
      {:ok, _} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "completed"
               })

      assert updated.reading_status == "completed"
    end

    test "transitions status to abandoned", %{user: user, placement: placement} do
      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "abandoned"
               })

      assert updated.reading_status == "abandoned"
    end

    test "sets started_at on first transition to reading", %{user: user, placement: placement} do
      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading"
               })

      assert updated.started_at != nil
    end

    test "does not overwrite started_at on subsequent reading transitions", %{
      user: user,
      placement: placement
    } do
      {:ok, first} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      original_started_at = first.started_at

      # Simulate going back to to_read and re-reading
      {:ok, _} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "to_read"})

      {:ok, second} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      assert second.started_at == original_started_at
    end

    test "sets finished_at on transition to completed", %{user: user, placement: placement} do
      {:ok, _} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "completed"
               })

      assert updated.finished_at != nil
    end

    test "does not set finished_at for non-completed transitions", %{
      user: user,
      placement: placement
    } do
      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading"
               })

      assert updated.finished_at == nil
    end

    test "updates current_page when provided", %{user: user, placement: placement} do
      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading",
                 current_page: 124
               })

      assert updated.current_page == 124
    end

    test "rejects negative current_page", %{user: user, placement: placement} do
      assert {:error, changeset} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading",
                 current_page: -1
               })

      assert %{current_page: [_]} = errors_on(changeset)
    end

    test "returns :unauthorized when user does not own placement", %{placement: placement} do
      other_user = insert(:user)

      assert {:error, :unauthorized} =
               Shelving.update_reading_progress(placement.id, other_user.id, %{
                 reading_status: "reading"
               })
    end

    test "returns :not_found for nonexistent placement id", %{user: user} do
      assert {:error, :not_found} =
               Shelving.update_reading_progress(Ecto.UUID.generate(), user.id, %{
                 reading_status: "reading"
               })
    end

    test "rejects invalid reading_status value", %{user: user, placement: placement} do
      assert {:error, changeset} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "invalid_status"
               })

      assert %{reading_status: [_]} = errors_on(changeset)
    end

    test "rejects current_page above the known primary-edition page count", %{user: user} do
      book = insert(:book)
      insert(:book_edition, book: book, page_count: 112, is_primary: true)
      bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:error, changeset} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading",
                 current_page: 999_999
               })

      assert %{current_page: [_]} = errors_on(changeset)
    end

    test "accepts current_page equal to the known page count (boundary)", %{user: user} do
      book = insert(:book)
      insert(:book_edition, book: book, page_count: 112, is_primary: true)
      bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
      placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading",
                 current_page: 112
               })

      assert updated.current_page == 112
    end

    test "permits any current_page when the page count is unknown", %{
      user: user,
      placement: placement
    } do
      # The setup book has no edition, so the primary-edition page count is
      # unknown. The ceiling is permissive in that case — a reader is never
      # blocked on missing catalogue metadata.
      assert {:ok, updated} =
               Shelving.update_reading_progress(placement.id, user.id, %{
                 reading_status: "reading",
                 current_page: 999_999
               })

      assert updated.current_page == 999_999
    end

    test "emits placement.reading_started event on first reading transition", %{
      user: user,
      placement: placement
    } do
      before_count = event_count("placement.reading_started")

      Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      assert event_count("placement.reading_started") == before_count + 1
    end

    test "does not emit placement.reading_started again on second reading transition", %{
      user: user,
      placement: placement
    } do
      # Start reading (sets started_at)
      {:ok, reading_placement} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      # Put back to to_read (started_at already set)
      {:ok, _} =
        Shelving.update_reading_progress(reading_placement.id, user.id, %{
          reading_status: "to_read"
        })

      before_count = event_count("placement.reading_started")

      # Re-transition to reading — started_at already set, no new event
      Shelving.update_reading_progress(reading_placement.id, user.id, %{
        reading_status: "reading"
      })

      assert event_count("placement.reading_started") == before_count
    end

    test "emits placement.reading_completed event on completed transition", %{
      user: user,
      placement: placement
    } do
      {:ok, _} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      before_count = event_count("placement.reading_completed")

      Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "completed"})

      assert event_count("placement.reading_completed") == before_count + 1
    end
  end

  describe "list_in_progress/1" do
    test "returns only placements with reading_status = reading" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book1 = insert(:book)
      book2 = insert(:book)
      book3 = insert(:book)

      p_reading = insert(:placement, bookshelf: bookshelf, book: book1)
      _p_to_read = insert(:placement, bookshelf: bookshelf, book: book2)
      _p_completed = insert(:placement, bookshelf: bookshelf, book: book3)

      Shelving.update_reading_progress(p_reading.id, user.id, %{reading_status: "reading"})

      in_progress = Shelving.list_in_progress(user.id)

      ids = Enum.map(in_progress, & &1.id)
      assert p_reading.id in ids
      refute Enum.any?(ids, &(&1 != p_reading.id))
    end

    test "returns empty list when user has no in-progress placements" do
      user = insert(:user)
      assert [] == Shelving.list_in_progress(user.id)
    end

    test "returns placements ordered by updated_at DESC" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book1 = insert(:book)
      book2 = insert(:book)

      p1 = insert(:placement, bookshelf: bookshelf, book: book1)
      p2 = insert(:placement, bookshelf: bookshelf, book: book2)

      {:ok, _} =
        Shelving.update_reading_progress(p1.id, user.id, %{reading_status: "reading"})

      {:ok, _} =
        Shelving.update_reading_progress(p2.id, user.id, %{reading_status: "reading"})

      in_progress = Shelving.list_in_progress(user.id)

      # p2 was updated last so it should be first
      assert hd(in_progress).id == p2.id
    end

    test "excludes placements belonging to other users" do
      user1 = insert(:user)
      user2 = insert(:user)
      bookshelf1 = insert(:bookshelf, user: user1, name: "library")
      bookshelf2 = insert(:bookshelf, user: user2, name: "library")
      book = insert(:book)

      p1 = insert(:placement, bookshelf: bookshelf1, book: book)
      p2 = insert(:placement, bookshelf: bookshelf2, book: book)

      Shelving.update_reading_progress(p1.id, user1.id, %{reading_status: "reading"})
      Shelving.update_reading_progress(p2.id, user2.id, %{reading_status: "reading"})

      user1_in_progress = Shelving.list_in_progress(user1.id)
      ids = Enum.map(user1_in_progress, & &1.id)

      assert p1.id in ids
      refute p2.id in ids
    end
  end

  # ---------------------------------------------------------------------------
  # Migration default value (Issue #148-W1)
  # ---------------------------------------------------------------------------

  describe "DB-level DEFAULT for reading_status" do
    test "reading_status defaults to 'to_read' at the database level when not supplied" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)

      shelf = insert(:shelf, bookshelf: bookshelf)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.insert_all(
        {"bookshelf_placements", Stacks.Shelving.Placement},
        [
          %{
            id: Ecto.UUID.generate(),
            book_id: book.id,
            bookshelf_id: bookshelf.id,
            shelf_id: shelf.id,
            position: 1,
            placed_at: now,
            formats: [],
            visibility: "owner",
            created_at: now,
            updated_at: now
          }
        ]
      )

      placement =
        Repo.one!(
          from(p in Stacks.Shelving.Placement,
            where: p.book_id == ^book.id and p.bookshelf_id == ^bookshelf.id
          )
        )

      assert placement.reading_status == "to_read"
    end
  end

  # ---------------------------------------------------------------------------
  # Event PAYLOAD assertions for move/remove (Issue #114, punch #16).
  #
  # The existing "emits placement.moved/removed event" tests assert only the row
  # COUNT. These pin the emitted PAYLOAD so a regression that fires the right
  # event type with a wrong/empty payload (or the wrong aggregate) fails.
  #
  # The exact payload keys are read from shelving.ex:
  #   placement.moved   -> %{from_bookshelf: <name>, to_bookshelf: <name>}
  #   placement.removed -> %{book_id: <uuid>}
  # (See the Phase 2 report flag: `placement.moved` carries the shelf NAMES, not
  # ids, and does NOT carry book_id — the aggregate_id is the placement id.)
  # ---------------------------------------------------------------------------

  describe "move_book/3 — placement.moved payload" do
    setup :setup_user_bookshelf_book

    test "payload carries the source and destination bookshelf names", %{
      user: user,
      placement: placement
    } do
      assert {:ok, _} = Shelving.move_book(placement.id, user.id, "wishlist")

      event = latest_event("placement.moved")
      {:ok, aggregate_id} = Ecto.UUID.load(event.aggregate_id)

      assert aggregate_id == placement.id
      assert event.payload["from_bookshelf"] == "library"
      assert event.payload["to_bookshelf"] == "wishlist"
    end
  end

  describe "remove_book/2 — placement.removed payload" do
    setup :setup_user_bookshelf_book

    test "payload carries the removed placement's book_id", %{
      user: user,
      book: book,
      placement: placement
    } do
      assert {:ok, _} = Shelving.remove_book(placement.id, user.id)

      event = latest_event("placement.removed")
      {:ok, aggregate_id} = Ecto.UUID.load(event.aggregate_id)

      assert aggregate_id == placement.id
      assert event.payload["book_id"] == book.id
    end
  end

  defp latest_event(event_type) do
    from(e in "event_log",
      prefix: "op",
      where: e.event_type == ^event_type,
      order_by: [desc: e.occurred_at],
      limit: 1,
      select: %{aggregate_id: e.aggregate_id, payload: e.payload}
    )
    |> Repo.one()
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  defp audit_count(action) do
    Repo.aggregate(
      from(a in "audit_log", prefix: "audit", where: a.action == ^action),
      :count
    )
  end

  # Newest audit row for an action, with its target columns. audit_log stores
  # user_id/resource_id as DUMPED binary UUIDs (Audit.log/3 → encode_uuid), so
  # callers compare against Ecto.UUID.dump!/1. Pins that a regression logging the
  # right action with a nil/wrong resource_id/resource_type/user_id would fail.
  defp latest_audit_row(action) do
    Repo.one(
      from(a in "audit_log",
        prefix: "audit",
        where: a.action == ^action,
        order_by: [desc: a.occurred_at],
        limit: 1,
        select: %{rt: a.resource_type, rid: a.resource_id, uid: a.user_id}
      )
    )
  end

  # Fills the user's reading_pile bookshelf with `count` active placements,
  # inserted directly (bypassing place_book) so over-limit grandfather
  # scenarios can be staged. Returns the bookshelf.
  defp fill_reading_pile(user, count) when count >= 1 do
    bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
    shelf = insert(:shelf, bookshelf: bookshelf)

    for _ <- 1..count do
      insert(:placement, bookshelf: bookshelf, shelf: shelf, book: insert(:book))
    end

    bookshelf
  end

  # Returns the book_ids visible on a bookshelf's browse — i.e. reached through
  # its PHYSICAL shelves (op.shelves, #151), exactly as get_bookshelf_shelves/2
  # feeds the browse UI. A placement whose shelf_id points at the source
  # bookshelf after a move is invisible here even though bookshelf_id updated.
  defp browse_book_ids(user_id, bookshelf_name) do
    user_id
    |> Shelving.get_bookshelf_shelves(bookshelf_name)
    |> Enum.flat_map(& &1.placements)
    |> Enum.map(& &1.book_id)
  end

  defp active_pile_count(user_id) do
    Repo.aggregate(
      from(p in Placement,
        join: b in Bookshelf,
        on: p.bookshelf_id == b.id,
        where: b.user_id == ^user_id and b.name == "reading_pile" and is_nil(p.removed_at)
      ),
      :count
    )
  end

  # #285 — discovery helpers backing the sectioned search response.
  describe "search_collection/3" do
    setup do
      user = insert(:user)
      other = insert(:user)
      {:ok, user: user, other: other}
    end

    test "returns the viewer's active-placement title matches only", %{user: user, other: other} do
      mine = insert(:book, title: "Tidewater Reckoning")
      place_on(user, mine, "library")

      theirs = insert(:book, title: "Tidewater Currents")
      place_on(other, theirs, "library")

      results = Shelving.search_collection(user.id, "Tidewater")
      ids = Enum.map(results, & &1.id)

      assert mine.id in ids
      refute theirs.id in ids
    end

    test "excludes removed placements", %{user: user} do
      book = insert(:book, title: "Vanished Copy")
      place_on(user, book, "library", removed_at: DateTime.utc_now())

      assert Shelving.search_collection(user.id, "Vanished Copy") == []
    end

    test "returns a book at most once even across multiple shelves", %{user: user} do
      book = insert(:book, title: "Twice Shelved")
      place_on(user, book, "library")
      place_on(user, book, "wishlist")

      results = Shelving.search_collection(user.id, "Twice Shelved")

      assert Enum.count(results, &(&1.id == book.id)) == 1
    end
  end

  describe "looking_for_home_labels/1" do
    test "labels only active looking_for_home placements with the owner handle" do
      owner = insert(:user, handle: "home_seeker")
      book = insert(:book, title: "Adrift")
      bookshelf = insert(:bookshelf, user: owner, name: "looking_for_home")
      shelf = insert(:shelf, bookshelf: bookshelf)
      insert(:placement, book: book, bookshelf: bookshelf, shelf: shelf, listing_status: "active")

      labels = Shelving.looking_for_home_labels([book.id])
      book_id = book.id

      assert %{^book_id => %{source: "looking_for_home", owner_handle: "home_seeker"}} = labels
    end

    test "ignores looking_for_home placements without an active listing_status" do
      owner = insert(:user)
      book = insert(:book)
      bookshelf = insert(:bookshelf, user: owner, name: "looking_for_home")
      shelf = insert(:shelf, bookshelf: bookshelf)
      insert(:placement, book: book, bookshelf: bookshelf, shelf: shelf)

      assert Shelving.looking_for_home_labels([book.id]) == %{}
    end

    test "ignores active listing_status on a non-LFH bookshelf" do
      owner = insert(:user)
      book = insert(:book)
      bookshelf = insert(:bookshelf, user: owner, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf)
      insert(:placement, book: book, bookshelf: bookshelf, shelf: shelf, listing_status: "active")

      assert Shelving.looking_for_home_labels([book.id]) == %{}
    end

    test "returns an empty map for no ids" do
      assert Shelving.looking_for_home_labels([]) == %{}
    end
  end
end
