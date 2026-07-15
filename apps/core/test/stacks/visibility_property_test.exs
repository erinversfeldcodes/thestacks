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

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # All visibility values accepted by the domain (Bookshelf schema allows
  # "owner", "group", "platform"; validate_visibility_ceiling also uses "public").
  defp visibility_gen do
    StreamData.member_of(["public", "platform", "owner"])
  end

  defp profile_visibility_gen do
    StreamData.member_of(["public", "platform", "owner"])
  end

  # Builds an in-memory Bookshelf with the given user_id, visibility, and a
  # preloaded User struct with the given profile_visibility.  Using a random
  # UUID as user_id means Accounts.get_user/1 will return nil, which the
  # visibility module treats as profile_visibility "owner" (most restrictive).
  # We control the profile_visibility by inserting a real user into the DB for
  # tests that exercise the non-owner viewer path.
  defp bookshelf_struct(user_id, visibility, profile_vis) do
    %Bookshelf{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      name: "library",
      visibility: visibility,
      user: %User{id: user_id, profile_visibility: profile_vis}
    }
  end

  # ---------------------------------------------------------------------------
  # Invariant 1: Owner always sees their own content
  #
  # The profile-ceiling check short-circuits (returns :ok) when viewer_id ==
  # owner_id.  The block check calls Social.blocked?/2 but since owner_id ==
  # viewer_id, it will return false (one cannot block oneself).  The resource
  # visibility check passes for any visibility when the viewer is the owner.
  # No DB insert needed — owner_id is a fresh UUID not in the DB.
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Invariant 2: owner-visibility bookshelf is always hidden from unauthenticated
  #
  # When bookshelf.visibility == "owner", check_resource_visibility always returns
  # :hidden for any non-owner viewer, including :unauthenticated.
  # The profile-ceiling check runs first but: for :unauthenticated, viewer_id is
  # nil, so check_block short-circuits; profile ceiling will call Accounts.get_user
  # with a random UUID (not in DB) → nil → treated as "owner" profile → :hidden.
  # Either way the result is :hidden.
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Invariant 3: owner profile_visibility hides all content from non-owner viewers
  #
  # When the owner's profile_visibility is "owner", no non-owner viewer can see
  # any content regardless of the resource's own visibility setting.
  # We insert a real user with profile_visibility "owner" so the DB lookup
  # succeeds and returns the correct profile_visibility.
  # ---------------------------------------------------------------------------

  property "owner profile_visibility hides bookshelf from any non-owner platform viewer" do
    # Each run inserts two Argon2-hashed users, so keep max_runs modest: the input
    # space here is just 2 values ("platform"/"owner"), so 25 runs covers it many
    # times over while staying well inside the 60s property timeout under CI load
    # (200 runs × 2 password hashes was the flake source, not a logic issue).
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

  # ---------------------------------------------------------------------------
  # Invariant 4: platform visibility + platform profile always visible to platform users
  #
  # When both visibility and profile_visibility are "platform" (permissive),
  # any authenticated platform user (who has no block relationship) can view the
  # bookshelf.  We insert real owner and viewer records so DB calls succeed.
  # ---------------------------------------------------------------------------

  property "platform visibility and platform profile is visible to any authenticated viewer" do
    # Two Argon2-hashed inserts per run; the display_name is incidental to the
    # invariant, so 25 runs is ample and stays inside the property timeout under
    # CI load (see the note on the previous property).
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

  # ---------------------------------------------------------------------------
  # Invariant 5: validate_visibility_ceiling rejects child less restrictive than parent
  #
  # "public" (rank 0) is less restrictive than "platform" (rank 1) and "owner"
  # (rank 2).  The function must return {:error, _} in both cases.
  # This is a pure in-memory computation — no DB access.
  # ---------------------------------------------------------------------------

  property "validate_visibility_ceiling rejects child less restrictive than parent" do
    check all(
            parent <- StreamData.member_of(["owner", "platform"]),
            resource_type <- StreamData.member_of([:bookshelf, :placement]),
            max_runs: 200
          ) do
      # "public" has rank 0, both parents have rank >= 1 → child < parent → error
      assert {:error, _reason} =
               Visibility.validate_visibility_ceiling("public", parent, resource_type)
    end
  end

  # ---------------------------------------------------------------------------
  # Invariant 6: validate_visibility_ceiling accepts equally or more-restrictive child
  # ---------------------------------------------------------------------------

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
