defmodule Stacks.ShelvingTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Shelving
  alias Stacks.Shelving.Placement
  alias Stacks.Shelving.PlacementHistory

  defp setup_user_shelf_book(_ctx) do
    user = insert(:user)
    shelf = insert(:bookshelf, user: user, name: "library")
    book = insert(:book)
    placement = insert(:placement, bookshelf: shelf, book: book)
    %{user: user, shelf: shelf, book: book, placement: placement}
  end

  describe "get_shelf_books/2" do
    setup :setup_user_shelf_book

    test "returns active placements on shelf", %{user: user, placement: placement} do
      placements = Shelving.get_shelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      assert placement.id in ids
    end

    test "excludes removed placements", %{user: user, placement: placement} do
      Shelving.remove_book(placement.id, user.id)
      placements = Shelving.get_shelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      refute placement.id in ids
    end

    test "returns empty list for shelf with no books", %{user: user} do
      assert [] == Shelving.get_shelf_books(user.id, "wishlist")
    end
  end

  describe "move_book/3" do
    setup :setup_user_shelf_book

    test "moves placement to new shelf and writes history", %{
      user: user,
      shelf: shelf,
      placement: placement
    } do
      assert {:ok, %{placement: _moved, history: history}} =
               Shelving.move_book(placement.id, user.id, "wishlist")

      moved_placement = Repo.get!(Placement, placement.id) |> Repo.preload(:bookshelf)
      assert moved_placement.bookshelf.name == "wishlist"

      assert history.book_id == placement.book_id
      assert history.from_bookshelf == shelf.id
    end

    test "creates history record in PlacementHistory table", %{
      user: user,
      shelf: shelf,
      placement: placement
    } do
      Shelving.move_book(placement.id, user.id, "wishlist")

      history =
        PlacementHistory
        |> Repo.get_by(book_id: placement.book_id, from_bookshelf: shelf.id)

      assert history != nil
    end
  end

  describe "remove_book/2" do
    setup :setup_user_shelf_book

    test "sets removed_at on the placement", %{user: user, placement: placement} do
      assert {:ok, removed} = Shelving.remove_book(placement.id, user.id)
      assert removed.removed_at != nil
    end

    test "placement no longer appears in shelf listing after removal", %{
      user: user,
      placement: placement
    } do
      Shelving.remove_book(placement.id, user.id)
      placements = Shelving.get_shelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      refute placement.id in ids
    end
  end

  describe "reread_book/1" do
    setup do
      user = insert(:user)
      # Use a non-library shelf so reread can create a fresh library placement
      shelf = insert(:bookshelf, user: user, name: "reading_pile")
      book = insert(:book)
      placement = insert(:placement, bookshelf: shelf, book: book)
      %{user: user, shelf: shelf, book: book, placement: placement}
    end

    test "creates a new placement on the library shelf", %{user: user, placement: placement} do
      assert {:ok, new_placement} = Shelving.reread_book(placement.id)
      assert new_placement.book_id == placement.book_id

      library_shelf = Repo.get_by(Stacks.Shelving.Bookshelf, user_id: user.id, name: "library")
      assert new_placement.bookshelf_id == library_shelf.id
    end

    test "new placement is separate from the original", %{placement: placement} do
      assert {:ok, new_placement} = Shelving.reread_book(placement.id)
      refute new_placement.id == placement.id
    end

    test "writes a PlacementHistory record from the original shelf to library", %{
      user: user,
      shelf: shelf,
      placement: placement
    } do
      assert {:ok, _new_placement} = Shelving.reread_book(placement.id)

      library_shelf = Repo.get_by(Stacks.Shelving.Bookshelf, user_id: user.id, name: "library")

      history =
        Repo.get_by(PlacementHistory,
          book_id: placement.book_id,
          from_bookshelf: shelf.id,
          to_bookshelf: library_shelf.id
        )

      assert history != nil
    end
  end

  describe "abandon_book/2" do
    setup :setup_user_shelf_book

    test "moves placement to looking_for_home shelf", %{user: user, placement: placement} do
      assert {:ok, _result} = Shelving.abandon_book(placement.id, user.id)

      moved = Repo.get!(Placement, placement.id) |> Repo.preload(:bookshelf)
      assert moved.bookshelf.name == "looking_for_home"
    end

    test "returns :unauthorized when user does not own the placement", %{placement: placement} do
      other_user = insert(:user)
      assert {:error, :unauthorized} = Shelving.abandon_book(placement.id, other_user.id)
    end
  end

  describe "spine_data/1" do
    setup :setup_user_shelf_book

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
end
