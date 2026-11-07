defmodule Stacks.SearchLabelsNeedAScopeTest do
  @moduledoc """
      The two cross-user label lookups behind search are **deliberately
      unscoped**, and the caller is the only place that can scope them.

      ⛔ WHY THEY ARE THE EXCEPTION. Lookups elsewhere scope themselves, because
      each always knows its user. These two take BOOK IDS and are cross-user by
      construction — "who is offering any of these books?" — so there is no user
      inside them to scope to. `SearchController` wraps them in
      `Scope.for_viewer/2` and that wrapper is the whole fix for a deployed
      defect: authenticated `GET /api/search` answered **500** for every signed-in
      caller, `42501 insufficient_privilege`, while anonymous search returned 200.

      ⚠️ So the wrapper is load-bearing and nothing was proving it. These cases
      assert the property directly rather than driving the controller, because the
      claim is about the FUNCTIONS: called without a scope they must be refused,
      not quietly return fewer rows.

      ⛔ Every case runs through `Core.AppRole.as_app_role/2`. Without it they all
      pass against a database with no policies at all — the suite connects as a
      superuser, which is precisely why this defect reached a deployed stack
      behind a green local run.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.AppRole
  alias Stacks.Marketplace
  alias Stacks.Scope
  alias Stacks.Shelving

  @unscoped_refusal "no request scope set"

  defp a_book_offered_by_someone_else do
    seller = insert(:user)
    book = insert(:book)
    shelf = insert(:bookshelf, user: seller, name: "looking_for_home")
    insert(:placement, bookshelf: shelf, book: book, listing_status: "active")
    %{seller: seller, book: book}
  end

  describe "an unscoped label lookup is REFUSED, not quietly empty" do
    test "looking_for_home_labels raises without a scope" do
      %{book: book} = a_book_offered_by_someone_else()

      error =
        assert_raise Postgrex.Error, fn ->
          AppRole.as_app_role(fn ->
            Shelving.looking_for_home_labels([book.id])
          end)
        end

      # ⛔ The refusal must name the missing scope. A bare permission error would
      # send the next reader looking at GRANTs instead of at the caller, which is
      # where the fix actually lives.
      assert error.postgres.message =~ @unscoped_refusal
    end

    test "active_listing_labels does NOT need one, and that is worth knowing" do
      %{book: book} = a_book_offered_by_someone_else()

      # ⛔ MEASURED, NOT ASSUMED — and it corrects the shape of the fix. This was
      # written expecting a refusal to match its sibling above, and it succeeded.
      # `active_listing_labels/1` reads `op.listings` joined to `op.users`, and
      # NEITHER is row-level secured; only `looking_for_home_labels/1` touches
      # `op.bookshelf_placements` and `op.bookshelves`.
      #
      # ⚠️ So `SearchController`'s `Scope.for_viewer/2` wraps two calls and only
      # ONE of them requires it. That matters for the next person to read that
      # wrapper: if the `looking_for_home` call ever moves out, the wrapper will
      # look redundant around what is left, and removing it will appear safe. It
      # is the other call that makes it load-bearing. This case exists so that
      # asymmetry is written down somewhere a test will keep honest.
      labels =
        AppRole.as_app_role(fn ->
          Marketplace.active_listing_labels([book.id])
        end)

      assert is_map(labels)
    end
  end

  describe "with the viewer's scope established, the same calls answer" do
    test "a signed-in viewer sees another reader's looking_for_home label" do
      %{book: book, seller: seller} = a_book_offered_by_someone_else()
      viewer = insert(:user)

      labels =
        Scope.for_viewer(viewer.id, fn ->
          AppRole.as_app_role(fn ->
            Shelving.looking_for_home_labels([book.id])
          end)
        end)

      # ⛔ ANTI-VACUITY, and the sharp half of it. An empty map would satisfy "did
      # not raise" while proving the opposite of what this issue is about: the
      # whole point is that a scoped call returns the CROSS-USER answer. If the
      # policy admitted only the viewer's own rows, this map would be empty and
      # search would silently stop telling anyone that a book is on offer.
      assert Map.has_key?(labels, book.id),
             "a scoped viewer must see another reader's offer; got #{inspect(labels)}"

      # The label is a map, not a bare handle — `%{source:, owner_handle:}`.
      assert labels[book.id].owner_handle == seller.handle
      assert labels[book.id].source == "looking_for_home"
    end

    test "an anonymous viewer is a scope too, and is not an error" do
      %{book: book} = a_book_offered_by_someone_else()

      labels =
        Scope.for_viewer(nil, fn ->
          AppRole.as_app_role(fn ->
            Shelving.looking_for_home_labels([book.id])
          end)
        end)

      # ⚖️ No assertion about the CONTENTS here, deliberately. What an anonymous
      # reader may see is the audience ladder's question and belongs to its own
      # tests; this one asserts only that `for_viewer(nil, …)` establishes a scope
      # rather than leaving the query refused, which is the branch a logged-out
      # search depends on.
      assert is_map(labels)
    end
  end
end
