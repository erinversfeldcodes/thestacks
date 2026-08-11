defmodule Stacks.VisibilityPropertyTest do
  @moduledoc """
    StreamData property-based tests for Stacks.Visibility invariants.

    Uses `Core.DataCase` (sync, shared sandbox) so that DB-touching paths inside
    `resolve_visibility/2` (profile-ceiling user load, block check) work correctly.

    Block invariants that require inserting block rows are left to the unit tests
    in `visibility_test.exs` — here we focus on structural invariants that hold
    across randomly generated combinations of visibility values and viewer types.
  """

  use Core.DataCase, async: false
  use ExUnitProperties

  import Stacks.Factory

  alias Stacks.Accounts.User
  alias Stacks.Shelving.Bookshelf
  alias Stacks.Visibility

  defp visibility_gen do
    StreamData.member_of(["public", "platform", "owner"])
  end

  defp profile_visibility_gen do
    StreamData.member_of(["public", "platform", "owner"])
  end

  defp bookshelf_struct(user_id, visibility, profile_vis) do
    %Bookshelf{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      name: "library",
      visibility: visibility,
      user: %User{id: user_id, profile_visibility: profile_vis}
    }
  end

  property "owner always sees their own bookshelf regardless of visibility settings" do
    check all(
            vis <- visibility_gen(),
            prof_vis <- profile_visibility_gen(),
            max_runs: 200
          ) do
      owner_id = Ecto.UUID.generate()
      bookshelf = bookshelf_struct(owner_id, vis, prof_vis)

      assert :visible == Visibility.resolve_visibility(bookshelf, {:platform_user, owner_id})
    end
  end

  property "owner-visibility bookshelf is always hidden from unauthenticated viewer" do
    check all(
            prof_vis <- profile_visibility_gen(),
            max_runs: 200
          ) do
      owner_id = Ecto.UUID.generate()
      bookshelf = bookshelf_struct(owner_id, "owner", prof_vis)

      assert :hidden == Visibility.resolve_visibility(bookshelf, :unauthenticated)
    end
  end

  property "owner profile_visibility hides bookshelf from any non-owner platform viewer" do
    check all(
            vis <- StreamData.member_of(["platform", "owner"]),
            max_runs: 25
          ) do
      owner = insert(:user, profile_visibility: "owner")
      viewer = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: vis)

      assert :hidden ==
               Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end
  end

  property "platform visibility and platform profile is visible to any authenticated viewer" do
    check all(
            viewer_display_name <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            max_runs: 25
          ) do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user, display_name: viewer_display_name)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :visible ==
               Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end
  end

  property "validate_visibility_ceiling rejects child less restrictive than parent" do
    check all(
            parent <- StreamData.member_of(["owner", "platform"]),
            resource_type <- StreamData.member_of([:bookshelf, :placement]),
            max_runs: 200
          ) do
      assert {:error, _reason} =
               Visibility.validate_visibility_ceiling("public", parent, resource_type)
    end
  end

  property "validate_visibility_ceiling accepts child equally or more restrictive than parent",
           %{} do
    check all(
            {child, parent} <-
              StreamData.one_of([
                StreamData.constant({"owner", "public"}),
                StreamData.constant({"owner", "platform"}),
                StreamData.constant({"owner", "owner"}),
                StreamData.constant({"platform", "public"}),
                StreamData.constant({"platform", "platform"}),
                StreamData.constant({"public", "public"})
              ]),
            max_runs: 200
          ) do
      assert :ok = Visibility.validate_visibility_ceiling(child, parent, :bookshelf)
    end
  end
end
