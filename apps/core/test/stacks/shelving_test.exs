defmodule Stacks.ShelvingTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Ecto.Adapters.SQL.Sandbox
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

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

  # Every reading-progress test moves a book the reader has NOT started:
  # `update_reading_progress/3` stamps `started_at` only on the FIRST move to
  # "reading", and a `finished_at` only ever arrives with "completed". A book on
  # a library shelf is one the factory takes to be finished already, so this says
  # otherwise out loud.
  defp setup_unread_placement(_ctx) do
    user = insert(:user)
    bookshelf = insert(:bookshelf, user: user, name: "library")
    book = insert(:book)

    placement =
      insert(:placement, bookshelf: bookshelf, book: book, reading_status: "to_read")

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

      assert book.id in browse_book_ids(user.id, "wishlist")

      assert {:ok, _} = Shelving.move_book(placement.id, user.id, "antilibrary")

      assert book.id in browse_book_ids(user.id, "antilibrary")
      refute book.id in browse_book_ids(user.id, "wishlist")
    end
  end

  describe "reading pile 50-item limit" do
    test "place_book/3 allows the 50th reading_pile placement" do
      user = insert(:user)
      fill_reading_pile(user, 49)
      book = insert(:book)

      assert {:ok, placement} = Shelving.place_book(user.id, book.id, "reading_pile")
      assert placement.book_id == book.id
      assert active_pile_count(user.id) == 50
    end

    @tag timeout: 180_000
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

      assert {:error, :reading_pile_full} = Shelving.place_book(user.id, book.id, "reading_pile")

      assert active_pile_count(user.id) == 55

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

      assert {:ok, %{placement: _}} = Shelving.move_book(placement.id, user.id, "reading_pile")
      assert active_pile_count(user.id) == 50
    end

    test "two concurrent placements cannot exceed the cap" do
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

      soft_deleted = Repo.get!(Placement, placement.id)
      assert soft_deleted.removed_at != nil

      assert Repo.get(Stacks.Books.Book, book.id) != nil
    end
  end

  describe "restore_placement/2 — undo of a removal" do
    setup do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: book,
          formats: ["physical", "ebook"],
          personal_rating: 5,
          notes: "Margin note about chapter nine",
          placed_at: ~U[2025-03-01 09:00:00.000000Z]
        )

      %{user: user, bookshelf: bookshelf, book: book, placement: placement}
    end

    test "restores the SAME row — same id, same placed_at, same annotations", %{
      user: user,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)

      assert {:ok, restored} = Shelving.restore_placement(placement.id, user.id)

      assert restored.id == placement.id
      assert restored.removed_at == nil

      rows = Repo.all(from p in Placement, where: p.book_id == ^placement.book_id)
      assert [row] = rows
      assert row.id == placement.id
      assert row.removed_at == nil

      assert row.placed_at == placement.placed_at
      assert row.formats == ["physical", "ebook"]
      assert row.personal_rating == 5
      assert row.notes == "Margin note about chapter nine"
    end

    test "the restored book is back in the bookshelf listing", %{
      user: user,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)
      refute placement.id in listing_ids(user)

      assert {:ok, _} = Shelving.restore_placement(placement.id, user.id)
      assert placement.id in listing_ids(user)
    end

    test "returns :not_found for a placement id that does not exist", %{user: user} do
      assert {:error, :not_found} = Shelving.restore_placement(Ecto.UUID.generate(), user.id)
    end

    test "returns :unauthorized for someone else's placement", %{
      user: user,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)
      other = insert(:user)

      assert {:error, :unauthorized} = Shelving.restore_placement(placement.id, other.id)

      assert Repo.get!(Placement, placement.id).removed_at != nil
    end

    test "removing does not move placed_at, so the undo has the real date to give back", %{
      user: user,
      placement: placement
    } do
      {:ok, removed} = Shelving.remove_book(placement.id, user.id)
      assert removed.placed_at == placement.placed_at

      {:ok, restored} = Shelving.restore_placement(placement.id, user.id)
      assert restored.placed_at == placement.placed_at
    end

    test "an unrelated placement edit does not move placed_at either", %{
      user: user,
      placement: placement
    } do
      assert {:ok, updated} =
               Shelving.update_placement_formats(placement.id, user.id, ["audiobook"])

      assert updated.placed_at == placement.placed_at
    end

    test "an already-active placement is a no-op success, not an error", %{
      user: user,
      placement: placement
    } do
      before_events = event_count("placement.restored")

      assert {:ok, restored} = Shelving.restore_placement(placement.id, user.id)
      assert restored.id == placement.id
      assert restored.removed_at == nil

      assert event_count("placement.restored") == before_events
    end

    test "emits placement.restored (and not placement.created)", %{
      user: user,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)

      restored_before = event_count("placement.restored")
      created_before = event_count("placement.created")

      assert {:ok, _} = Shelving.restore_placement(placement.id, user.id)

      assert event_count("placement.restored") == restored_before + 1
      assert event_count("placement.created") == created_before
    end

    test "writes an audit-log entry naming the placement and the actor", %{
      user: user,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)
      before_count = audit_count("placement.restored")

      assert {:ok, _} = Shelving.restore_placement(placement.id, user.id)

      assert audit_count("placement.restored") == before_count + 1

      row = latest_audit_row("placement.restored")
      assert row.rt == "placement"
      assert row.rid == Ecto.UUID.dump!(placement.id)
      assert row.uid == Ecto.UUID.dump!(user.id)
    end

    test "refuses with :already_shelved when the book was re-added meanwhile", %{
      user: user,
      book: book,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)
      {:ok, readded} = Shelving.place_book(user.id, book.id, "library")

      assert {:error, :already_shelved} = Shelving.restore_placement(placement.id, user.id)

      assert Repo.get!(Placement, placement.id).removed_at != nil
      assert Repo.get!(Placement, readded.id).removed_at == nil
      assert listing_ids(user) == [readded.id]
    end

    test "the refusal announces nothing — no event, no audit row", %{
      user: user,
      book: book,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)
      {:ok, _} = Shelving.place_book(user.id, book.id, "library")

      events_before = event_count("placement.restored")
      audits_before = audit_count("placement.restored")

      assert {:error, :already_shelved} = Shelving.restore_placement(placement.id, user.id)

      assert event_count("placement.restored") == events_before
      assert audit_count("placement.restored") == audits_before
    end

    test "a re-add on a DIFFERENT bookshelf does not block the undo", %{
      user: user,
      book: book,
      placement: placement
    } do
      {:ok, _} = Shelving.remove_book(placement.id, user.id)
      {:ok, elsewhere} = Shelving.place_book(user.id, book.id, "wishlist")

      assert {:ok, restored} = Shelving.restore_placement(placement.id, user.id)
      assert restored.id == placement.id
      assert Repo.get!(Placement, elsewhere.id).removed_at == nil
    end
  end

  defp listing_ids(user) do
    user.id
    |> Shelving.get_bookshelf_books("library")
    |> Enum.map(& &1.id)
  end

  describe "reread_book/2" do
    setup do
      user = insert(:user)
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
      insert(:shelf, bookshelf: bookshelf, position: 0)

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

  describe "get_placements_for_book/2 — a book on several bookshelves" do
    test "returns every active placement, oldest first" do
      user = insert(:user)
      book = insert(:book)
      first = place_on(user, book, "library")
      second = place_on(user, book, "wishlist")

      placements = Shelving.get_placements_for_book(user.id, book.id)

      assert Enum.map(placements, & &1.id) == [first.id, second.id]
      assert Enum.map(placements, & &1.bookshelf.name) == ["library", "wishlist"]
    end

    test "the bookshelf is preloaded, so the serialiser never sees NotLoaded" do
      user = insert(:user)
      book = insert(:book)
      place_on(user, book, "antilibrary")

      assert [%Placement{bookshelf: %Bookshelf{name: "antilibrary"}}] =
               Shelving.get_placements_for_book(user.id, book.id)
    end

    test "returns [] — never nil — for a book the user has not placed" do
      assert Shelving.get_placements_for_book(insert(:user).id, insert(:book).id) == []
    end

    test "omits removed placements" do
      user = insert(:user)
      book = insert(:book)
      place_on(user, book, "library")
      place_on(user, book, "wishlist", removed_at: DateTime.utc_now())

      assert [%{bookshelf: %{name: "library"}}] =
               Shelving.get_placements_for_book(user.id, book.id)
    end

    test "does not return another user's placement of the same book" do
      user = insert(:user)
      stranger = insert(:user)
      book = insert(:book)
      place_on(user, book, "library")
      place_on(stranger, book, "library")

      assert [mine] = Shelving.get_placements_for_book(user.id, book.id)
      assert mine.bookshelf.user_id == user.id
    end

    test "place_book/3 reaches four bookshelves through the production write path" do
      user = insert(:user)
      book = insert(:book)

      for name <- ~w(library antilibrary reading_pile wishlist) do
        assert {:ok, _} = Shelving.place_book(user.id, book.id, name)
      end

      assert user.id
             |> Shelving.get_placements_for_book(book.id)
             |> Enum.map(& &1.bookshelf.name)
             |> Enum.sort() == ~w(antilibrary library reading_pile wishlist)
    end

    test "a second active placement on the SAME bookshelf is refused with a clean error" do
      user = insert(:user)
      book = insert(:book)
      assert {:ok, _} = Shelving.place_book(user.id, book.id, "library")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Shelving.place_book(user.id, book.id, "library")

      assert "book is already on this bookshelf" in errors_on(changeset).book_id
      assert length(Shelving.get_placements_for_book(user.id, book.id)) == 1
    end

    test "rung 4 refuses the same-bookshelf duplicate even when the changeset is bypassed" do
      user = insert(:user)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")

      assert_raise Ecto.ConstraintError, ~r/bookshelf_placements_book_active_idx/, fn ->
        Repo.insert!(%Placement{
          book_id: book.id,
          bookshelf_id: placement.bookshelf_id,
          shelf_id: placement.shelf_id,
          placed_at: DateTime.utc_now()
        })
      end
    end

    test "re-placing on a bookshelf the book was REMOVED from is allowed" do
      user = insert(:user)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")
      {:ok, _} = Shelving.remove_book(placement.id, user.id)

      assert {:ok, _} = Shelving.place_book(user.id, book.id, "library")
      assert length(Shelving.get_placements_for_book(user.id, book.id)) == 1
    end
  end

  describe "update_placement_formats/3" do
    setup :setup_user_bookshelf_book

    test "updates the formats list for an owned placement", %{user: user, placement: placement} do
      assert {:ok, updated} =
               Shelving.update_placement_formats(placement.id, user.id, ["physical"])

      assert updated.formats == ["physical"]
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

  describe "update_bookshelf_visibility/3" do
    setup :setup_user_bookshelf_book

    test "owner can update bookshelf visibility" do
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

    test "rejects visibility that exceeds the profile ceiling" do
      user = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert {:error, changeset} =
               Shelving.update_bookshelf_visibility(bookshelf.id, user.id, "platform")

      assert %{visibility: [_]} = errors_on(changeset)
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

  describe "update_reading_progress/3" do
    setup :setup_unread_placement

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
      book = insert(:book, editions: [build(:primary_book_edition, page_count: 112)])
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
      book = insert(:book, editions: [build(:primary_book_edition, page_count: 112)])
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
      bookshelf: bookshelf
    } do
      book = insert(:book, editions: [build(:primary_book_edition, page_count: nil)])
      placement = insert(:placement, bookshelf: bookshelf, book: book)

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
      {:ok, reading_placement} =
        Shelving.update_reading_progress(placement.id, user.id, %{reading_status: "reading"})

      {:ok, _} =
        Shelving.update_reading_progress(reading_placement.id, user.id, %{
          reading_status: "to_read"
        })

      before_count = event_count("placement.reading_started")

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

  defp fill_reading_pile(user, count) when count >= 1 do
    bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
    shelf = insert(:shelf, bookshelf: bookshelf)

    for _ <- 1..count do
      insert(:placement, bookshelf: bookshelf, shelf: shelf, book: insert(:book))
    end

    bookshelf
  end

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
      ids = Enum.map(results, & &1.book.id)

      assert mine.id in ids
      refute theirs.id in ids
    end

    test "tags each hit with the bookshelf it sits on", %{user: user} do
      book = insert(:book, title: "Shelf Tagged")
      place_on(user, book, "wishlist")

      assert [%{book: hit_book, bookshelf_name: "wishlist"}] =
               Shelving.search_collection(user.id, "Shelf Tagged")

      assert hit_book.id == book.id
    end

    test "excludes removed placements", %{user: user} do
      book = insert(:book, title: "Vanished Copy")
      place_on(user, book, "library", removed_at: DateTime.utc_now())

      assert Shelving.search_collection(user.id, "Vanished Copy") == []
    end

    test "returns a book at most once across multiple shelves, naming every shelf", %{user: user} do
      book = insert(:book, title: "Twice Shelved")
      place_on(user, book, "library")
      place_on(user, book, "wishlist")

      results = Shelving.search_collection(user.id, "Twice Shelved")

      assert Enum.count(results, &(&1.book.id == book.id)) == 1
      assert [%{bookshelf_name: "library", bookshelf_names: ["library", "wishlist"]}] = results
    end

    test "a single-shelf hit reports exactly that one shelf", %{user: user} do
      book = insert(:book, title: "Once Shelved")
      place_on(user, book, "reading_pile")

      assert [%{bookshelf_names: ["reading_pile"]}] =
               Shelving.search_collection(user.id, "Once Shelved")
    end

    test "a removed placement is not named among a book's shelves", %{user: user} do
      book = insert(:book, title: "Partly Vanished")
      place_on(user, book, "library")
      place_on(user, book, "wishlist", removed_at: DateTime.utc_now())

      assert [%{bookshelf_names: ["library"]}] =
               Shelving.search_collection(user.id, "Partly Vanished")
    end

    test "another reader's shelves are never named on your hit", %{user: user, other: other} do
      book = insert(:book, title: "Shared Title")
      place_on(user, book, "library")
      place_on(other, book, "reading_pile")

      assert [%{bookshelf_names: ["library"]}] =
               Shelving.search_collection(user.id, "Shared Title")
    end

    test "under deep scope, ranks a title match above an alphabetically-earlier description-only match",
         %{user: user} do
      desc_only =
        insert(:book, title: "Aardvark Almanac", description: "A field study of zephyr winds.")

      place_on(user, desc_only, "library")

      title_match =
        insert(:book, title: "Zephyr Chronicles", description: "Nothing relevant here.")

      place_on(user, title_match, "wishlist")

      results = Shelving.search_collection(user.id, "zephyr", scope: :deep)
      ids = Enum.map(results, & &1.book.id)

      assert ids == [title_match.id, desc_only.id],
             "the title match must rank ahead of the description-only match under deep scope"
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
