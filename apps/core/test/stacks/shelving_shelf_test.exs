defmodule Stacks.ShelvingShelfTest do
  @moduledoc """
  Tests for physical shelf management within bookshelves.
  These functions do not exist yet — tests are expected to fail.
  """

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Shelving

  # ---------------------------------------------------------------------------
  # Setup helpers
  # ---------------------------------------------------------------------------

  defp setup_user_bookshelf(_ctx) do
    user = insert(:user)
    bookshelf = insert(:bookshelf, user: user, name: "library")
    %{user: user, bookshelf: bookshelf}
  end

  defp setup_with_shelves(%{user: user, bookshelf: bookshelf}) do
    shelf_a = insert(:shelf, bookshelf: bookshelf, position: 0)
    shelf_b = insert(:shelf, bookshelf: bookshelf, position: 1)
    shelf_c = insert(:shelf, bookshelf: bookshelf, position: 2)
    %{user: user, bookshelf: bookshelf, shelf_a: shelf_a, shelf_b: shelf_b, shelf_c: shelf_c}
  end

  # ---------------------------------------------------------------------------
  # list_shelves/1
  # ---------------------------------------------------------------------------

  describe "list_shelves/1" do
    setup [:setup_user_bookshelf, :setup_with_shelves]

    test "returns shelves in ascending position order", %{
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b,
      shelf_c: shelf_c
    } do
      shelves = Shelving.list_shelves(bookshelf.id)
      ids = Enum.map(shelves, & &1.id)
      assert ids == [shelf_a.id, shelf_b.id, shelf_c.id]
    end

    test "returns empty list for bookshelf with no shelves" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "wishlist")
      assert [] == Shelving.list_shelves(bookshelf.id)
    end
  end

  # ---------------------------------------------------------------------------
  # create_shelf/2
  # ---------------------------------------------------------------------------

  describe "create_shelf/2" do
    setup :setup_user_bookshelf

    test "creates a shelf on the bookshelf", %{user: user, bookshelf: bookshelf} do
      assert {:ok, shelf} = Shelving.create_shelf(bookshelf.id, user.id)
      assert shelf.bookshelf_id == bookshelf.id
    end

    test "assigns next position automatically", %{user: user, bookshelf: bookshelf} do
      {:ok, first} = Shelving.create_shelf(bookshelf.id, user.id)
      {:ok, second} = Shelving.create_shelf(bookshelf.id, user.id)
      assert second.position > first.position
    end

    test "returns :unauthorized if user does not own the bookshelf", %{bookshelf: bookshelf} do
      other_user = insert(:user)
      assert {:error, :unauthorized} = Shelving.create_shelf(bookshelf.id, other_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # delete_shelf/2
  # ---------------------------------------------------------------------------

  describe "delete_shelf/2" do
    setup [:setup_user_bookshelf, :setup_with_shelves]

    test "deletes an empty shelf", %{user: user, shelf_c: shelf_c} do
      assert :ok = Shelving.delete_shelf(shelf_c.id, user.id)
    end

    test "returns :not_empty when shelf has placements", %{
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a
    } do
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)
      assert {:error, :not_empty} = Shelving.delete_shelf(shelf_a.id, user.id)
    end

    test "returns :unauthorized if user does not own the bookshelf", %{shelf_a: shelf_a} do
      other_user = insert(:user)
      assert {:error, :unauthorized} = Shelving.delete_shelf(shelf_a.id, other_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # reorder_shelves/3
  # ---------------------------------------------------------------------------

  describe "reorder_shelves/3" do
    setup [:setup_user_bookshelf, :setup_with_shelves]

    test "updates positions to match given order", %{
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b,
      shelf_c: shelf_c
    } do
      # Reverse the order: C, B, A
      assert :ok =
               Shelving.reorder_shelves(bookshelf.id, user.id, [
                 shelf_c.id,
                 shelf_b.id,
                 shelf_a.id
               ])

      shelves = Shelving.list_shelves(bookshelf.id)
      ids = Enum.map(shelves, & &1.id)
      assert ids == [shelf_c.id, shelf_b.id, shelf_a.id]
    end

    test "returns :invalid_ids when a shelf_id does not belong to this bookshelf", %{
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      other_user = insert(:user)
      other_bookshelf = insert(:bookshelf, user: other_user, name: "library")
      foreign_shelf = insert(:shelf, bookshelf: other_bookshelf, position: 0)

      assert {:error, :invalid_ids} =
               Shelving.reorder_shelves(bookshelf.id, user.id, [
                 shelf_a.id,
                 shelf_b.id,
                 foreign_shelf.id
               ])
    end

    test "returns :unauthorized if user does not own the bookshelf", %{
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b,
      shelf_c: shelf_c
    } do
      other_user = insert(:user)

      assert {:error, :unauthorized} =
               Shelving.reorder_shelves(bookshelf.id, other_user.id, [
                 shelf_a.id,
                 shelf_b.id,
                 shelf_c.id
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # move_placement_to_shelf/3
  # ---------------------------------------------------------------------------

  describe "move_placement_to_shelf/3" do
    setup [:setup_user_bookshelf, :setup_with_shelves]

    test "moves a placement to a different shelf on the same bookshelf", %{
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      assert {:ok, updated} = Shelving.move_placement_to_shelf(placement.id, shelf_b.id, user.id)
      assert updated.shelf_id == shelf_b.id
    end

    test "returns :wrong_bookshelf when target shelf is on a different bookshelf", %{
      user: user,
      bookshelf: bookshelf,
      shelf_a: shelf_a
    } do
      other_bookshelf = insert(:bookshelf, user: user, name: "wishlist")
      other_shelf = insert(:shelf, bookshelf: other_bookshelf, position: 0)

      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)

      assert {:error, :wrong_bookshelf} =
               Shelving.move_placement_to_shelf(placement.id, other_shelf.id, user.id)
    end

    test "returns :unauthorized when user does not own the placement", %{
      bookshelf: bookshelf,
      shelf_a: shelf_a,
      shelf_b: shelf_b
    } do
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, shelf: shelf_a)
      other_user = insert(:user)

      assert {:error, :unauthorized} =
               Shelving.move_placement_to_shelf(placement.id, shelf_b.id, other_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Invariant: all placements belong to a shelf
  # ---------------------------------------------------------------------------

  describe "shelf invariant" do
    setup :setup_user_bookshelf

    test "after create_shelf, new placements are assigned to a shelf", %{
      user: user,
      bookshelf: bookshelf
    } do
      {:ok, shelf} = Shelving.create_shelf(bookshelf.id, user.id)
      book = insert(:book)
      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")

      reloaded = Repo.get!(Stacks.Shelving.Placement, placement.id)
      assert reloaded.shelf_id != nil
    end
  end
end
