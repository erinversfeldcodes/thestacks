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

    test "active listing on non-looking_for_home shelf → no marketplace exception" do
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "owner")

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          visibility: "platform",
          listing_status: "active"
        )

      viewer = insert(:user)

      assert :hidden = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end

    test "active looking_for_home listing is :hidden for a viewer the owner has blocked (SEC-2)" do
      # A block hides ALL of the owner's content — the marketplace exception must
      # not punch through the bidirectional block.
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, name: "looking_for_home", visibility: "owner")

      placement =
        insert(:placement, bookshelf: bookshelf, visibility: "platform", listing_status: "active")

      viewer = insert(:user)
      {:ok, _} = Stacks.Social.block_user(owner.id, viewer.id)

      assert :hidden = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — platform preview (ViewAs :platform perspective)
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — platform preview" do
    test "platform preview does NOT see owner-only content (SEC-1)" do
      owner = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "owner")

      placement =
        insert(:placement, bookshelf: bookshelf, visibility: "owner", listing_status: nil)

      assert :hidden = Visibility.resolve_visibility(placement, :platform_preview)
    end

    test "platform preview sees platform-visible content (SEC-1)" do
      owner = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")

      placement =
        insert(:placement, bookshelf: bookshelf, visibility: "platform", listing_status: nil)

      assert :visible = Visibility.resolve_visibility(placement, :platform_preview)
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
  # resolve_visibility/2 — group visibility
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — group visibility" do
    test "group visibility + viewer is group member → :visible" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: viewer)

      bookshelf =
        insert(:bookshelf, user: owner, visibility: "group", visibility_group_id: group.id)

      assert :visible = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end

    test "group visibility + viewer not a group member → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      group = insert(:group, owner: owner)

      bookshelf =
        insert(:bookshelf, user: owner, visibility: "group", visibility_group_id: group.id)

      assert :hidden = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end

    test "group visibility + no visibility_group_id set → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")

      assert :hidden = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end

    test "group visibility + owner → :visible (owner check applies before group)" do
      owner = insert(:user, profile_visibility: "platform")
      group = insert(:group, owner: owner)

      bookshelf =
        insert(:bookshelf, user: owner, visibility: "group", visibility_group_id: group.id)

      assert :visible = Visibility.resolve_visibility(bookshelf, {:platform_user, owner.id})
    end

    test "group visibility + unauthenticated viewer → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      group = insert(:group, owner: owner)

      bookshelf =
        insert(:bookshelf, user: owner, visibility: "group", visibility_group_id: group.id)

      assert :hidden = Visibility.resolve_visibility(bookshelf, :unauthenticated)
    end

    test "placement with group visibility + viewer is group member → :visible" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: viewer)

      bookshelf =
        insert(:bookshelf, user: owner, visibility: "group", visibility_group_id: group.id)

      placement = insert(:placement, bookshelf: bookshelf, visibility: "group")

      assert :visible = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end

    test "placement with group visibility + viewer not a group member → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      group = insert(:group, owner: owner)

      bookshelf =
        insert(:bookshelf, user: owner, visibility: "group", visibility_group_id: group.id)

      placement = insert(:placement, bookshelf: bookshelf, visibility: "group")

      assert :hidden = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — resource visibility edge cases
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — resource visibility edge cases" do
    test "resource with only visibility_tier (no visibility field) treated as public" do
      book = insert(:book, visibility_tier: "public")
      viewer = insert(:user)

      assert :visible = Visibility.resolve_visibility(book, {:platform_user, viewer.id})
    end

    test "resource with only visibility_tier for unauthenticated viewer → :visible" do
      book = insert(:book, visibility_tier: "public")

      assert :visible = Visibility.resolve_visibility(book, :unauthenticated)
    end

    test "resource with neither visibility nor visibility_tier defaults to owner-only" do
      # A plain map without visibility or visibility_tier — get_resource_visibility returns "owner"
      resource = %{user_id: Ecto.UUID.generate()}

      assert :hidden = Visibility.resolve_visibility(resource, :unauthenticated)
    end

    test "unknown visibility falls back to check_default_visibility — owner can view" do
      owner = insert(:user, profile_visibility: "platform")
      # A resource with an unknown visibility string
      resource = %{user_id: owner.id, visibility: "custom_unknown"}

      assert :visible = Visibility.resolve_visibility(resource, {:platform_user, owner.id})
    end

    test "unknown visibility falls back to check_default_visibility — non-owner hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      resource = %{user_id: owner.id, visibility: "custom_unknown"}

      assert :hidden = Visibility.resolve_visibility(resource, {:platform_user, viewer.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — placement with unloaded bookshelf
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — placement profile visibility edge cases" do
    test "placement with bookshelf whose user is nil → profile ceiling defaults to owner" do
      # Placement where bookshelf association has no user_id
      owner = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          visibility: "platform",
          listing_status: nil
        )

      viewer = insert(:user)

      assert :visible = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_visibility/2 — age gate for unauthenticated
  # ---------------------------------------------------------------------------

  describe "resolve_visibility/2 — age gate unauthenticated" do
    test "book with visibility_tier age_gated + unauthenticated → :hidden" do
      book = insert(:book, visibility_tier: "age_gated")

      assert :hidden = Visibility.resolve_visibility(book, :unauthenticated)
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

  # ---------------------------------------------------------------------------
  # viewable_shelves/2
  # ---------------------------------------------------------------------------

  describe "viewable_shelves/2" do
    test "returns only visible bookshelves for platform user" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      platform_shelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
      _owner_shelf = insert(:bookshelf, user: owner, name: "antilibrary", visibility: "owner")

      result = Visibility.viewable_shelves(owner.id, {:platform_user, viewer.id})

      assert length(result) == 1
      assert hd(result).id == platform_shelf.id
    end

    test "owner sees all their own bookshelves" do
      owner = insert(:user, profile_visibility: "platform")
      _platform_shelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
      _owner_shelf = insert(:bookshelf, user: owner, name: "antilibrary", visibility: "owner")

      result = Visibility.viewable_shelves(owner.id, {:platform_user, owner.id})

      assert length(result) == 2
    end

    test "unauthenticated viewer sees only platform-visible bookshelves" do
      owner = insert(:user, profile_visibility: "platform")
      _platform_shelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
      _owner_shelf = insert(:bookshelf, user: owner, name: "antilibrary", visibility: "owner")

      result = Visibility.viewable_shelves(owner.id, :unauthenticated)

      assert length(result) == 1
    end
  end
end
