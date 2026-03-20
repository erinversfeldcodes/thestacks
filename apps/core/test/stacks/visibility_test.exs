defmodule Stacks.VisibilityTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Visibility

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — profile ceiling
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — profile ceiling" do
    test "unauthenticated viewer + private bookshelf (profile_visibility: owner) → :hidden" do
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, visibility: "owner")

      assert :hidden = Visibility.resolve_visibility(bookshelf, :unauthenticated)
    end

    test "unauthenticated viewer + public bookshelf (profile_visibility: platform) → :visible" do
      owner = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :visible = Visibility.resolve_visibility(bookshelf, :unauthenticated)
    end

    test "platform user viewer + profile_visibility owner (not owner of resource) → :hidden" do
      owner = insert(:user, profile_visibility: "owner")
      viewer = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :hidden = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end

    test "owner viewing their own private content → :visible" do
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, visibility: "owner")

      assert :visible = Visibility.resolve_visibility(bookshelf, {:platform_user, owner.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — block check
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — block check" do
    test "viewer is blocked by resource owner → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      # owner blocks viewer
      insert(:user_block, blocker: owner, blocked: viewer)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :hidden = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end

    test "viewer has blocked resource owner → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      # viewer blocks owner
      insert(:user_block, blocker: viewer, blocked: owner)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :hidden = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end

    test "viewer with no block relationship + visible content → :visible" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :visible = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — age gate
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — age gate" do
    test "book with visibility_tier age_gated + unverified viewer → :hidden" do
      book = insert(:book, visibility_tier: "age_gated")
      viewer = insert(:user, age_verified: false)

      assert :hidden = Visibility.resolve_visibility(book, {:platform_user, viewer.id})
    end

    test "book with visibility_tier age_gated + age-verified viewer → :visible" do
      book = insert(:book, visibility_tier: "age_gated")
      viewer = insert(:user, age_verified: true)

      assert :visible = Visibility.resolve_visibility(book, {:platform_user, viewer.id})
    end

    test "book with visibility_tier public + unverified viewer → :visible" do
      book = insert(:book, visibility_tier: "public")
      viewer = insert(:user, age_verified: false)

      assert :visible = Visibility.resolve_visibility(book, {:platform_user, viewer.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — marketplace exception
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — marketplace exception" do
    test "active looking_for_home placement with profile_visibility owner → :visible for platform user" do
      # Profile ceiling is "owner" but active marketplace listing punches through for platform users
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, name: "looking_for_home", visibility: "owner")

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          visibility: "platform",
          listing_status: "active"
        )

      viewer = insert(:user)

      assert :visible = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end

    test "active looking_for_home placement with profile_visibility owner → :hidden for unauthenticated" do
      # Marketplace exception only applies to platform users, not unauthenticated
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, name: "looking_for_home", visibility: "owner")

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          visibility: "platform",
          listing_status: "active"
        )

      assert :hidden = Visibility.resolve_visibility(placement, :unauthenticated)
    end

    test "library placement with nil listing_status + profile_visibility owner → :hidden for platform user" do
      # No marketplace exception for non-looking_for_home shelves
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "owner")

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          visibility: "owner",
          listing_status: nil
        )

      viewer = insert(:user)

      assert :hidden = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — returns :hidden on error/ambiguity
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — returns :hidden on error/ambiguity" do
    test "nil resource → :hidden" do
      assert :hidden = Visibility.resolve_visibility(nil, {:platform_user, Ecto.UUID.generate()})
    end

    test "unknown viewer type → :hidden" do
      book = insert(:book, visibility_tier: "public")

      assert :hidden = Visibility.resolve_visibility(book, {:unknown_viewer_type, "something"})
    end
  end

  # ---------------------------------------------------------------------------
  # validate_visibility_ceiling/3
  # ---------------------------------------------------------------------------

  describe "validate_visibility_ceiling/3" do
    test "child visibility platform with parent visibility owner → error (child > parent)" do
      assert {:error, _reason} =
               Visibility.validate_visibility_ceiling("platform", "owner", :bookshelf)
    end

    test "child visibility owner with parent visibility platform → ok (child ≤ parent)" do
      assert :ok = Visibility.validate_visibility_ceiling("owner", "platform", :bookshelf)
    end

    test "same visibility → ok" do
      assert :ok = Visibility.validate_visibility_ceiling("platform", "platform", :bookshelf)
    end
  end

  # ---------------------------------------------------------------------------
  # can_view?/2
  # ---------------------------------------------------------------------------

  describe "can_view?/2" do
    test "wraps resolve_visibility: visible → true" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert true == Visibility.can_view?(bookshelf, {:platform_user, viewer.id})
    end

    test "wraps resolve_visibility: hidden → false" do
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, visibility: "owner")

      assert false == Visibility.can_view?(bookshelf, :unauthenticated)
    end
  end
end
