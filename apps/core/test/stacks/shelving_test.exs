defmodule Stacks.ShelvingTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

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
  end

  describe "remove_book/2" do
    setup :setup_user_bookshelf_book

    test "sets removed_at on the placement", %{user: user, placement: placement} do
      assert {:ok, removed} = Shelving.remove_book(placement.id, user.id)
      assert removed.removed_at != nil
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
  end

  describe "reread_book/1" do
    setup do
      user = insert(:user)
      # Use a non-library bookshelf so reread can create a fresh library placement
      bookshelf = insert(:bookshelf, user: user, name: "reading_pile")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book)
      %{user: user, bookshelf: bookshelf, book: book, placement: placement}
    end

    test "creates a new placement on the library bookshelf", %{user: user, placement: placement} do
      assert {:ok, new_placement} = Shelving.reread_book(placement.id)
      assert new_placement.book_id == placement.book_id

      library_bookshelf = Repo.get_by(Bookshelf, user_id: user.id, name: "library")
      assert new_placement.bookshelf_id == library_bookshelf.id
    end

    test "new placement is separate from the original", %{placement: placement} do
      assert {:ok, new_placement} = Shelving.reread_book(placement.id)
      refute new_placement.id == placement.id
    end

    test "writes a PlacementHistory record from the original bookshelf to library", %{
      user: user,
      bookshelf: bookshelf,
      placement: placement
    } do
      assert {:ok, _new_placement} = Shelving.reread_book(placement.id)

      library_bookshelf = Repo.get_by(Bookshelf, user_id: user.id, name: "library")

      history =
        Repo.get_by(PlacementHistory,
          book_id: placement.book_id,
          from_bookshelf: bookshelf.id,
          to_bookshelf: library_bookshelf.id
        )

      assert history != nil
    end

    test "emits placement.reread event", %{placement: placement} do
      before_count = event_count("placement.reread")

      Shelving.reread_book(placement.id)

      assert event_count("placement.reread") == before_count + 1
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
  end

  describe "remove_book/2 — unauthorized" do
    setup :setup_user_bookshelf_book

    test "returns :unauthorized when user does not own the placement", %{placement: placement} do
      other_user = insert(:user)
      assert {:error, :unauthorized} = Shelving.remove_book(placement.id, other_user.id)
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

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end
end
