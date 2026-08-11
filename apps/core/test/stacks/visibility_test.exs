defmodule Stacks.VisibilityTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Visibility

  describe "resolve_visibility/2 — profile ceiling" do
    test "unauthenticated viewer + private bookshelf (profile_visibility: owner) → :hidden" do
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, visibility: "owner")

      assert :hidden = Visibility.resolve_visibility(bookshelf, :unauthenticated)
    end

    test "unauthenticated viewer + platform (Members) bookshelf →:hidden (signed-in only, )" do
      owner = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :hidden = Visibility.resolve_visibility(bookshelf, :unauthenticated)
    end

    test "unauthenticated viewer + public bookshelf + public profile →:visible" do
      owner = insert(:user, profile_visibility: "public")
      bookshelf = insert(:bookshelf, user: owner, visibility: "public")

      assert :visible = Visibility.resolve_visibility(bookshelf, :unauthenticated)
    end

    test "signed-in viewer + platform (Members) bookshelf → :visible" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :visible = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
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

  describe "resolve_visibility/2 — block check" do
    test "viewer is blocked by resource owner → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      insert(:user_block, blocker: owner, blocked: viewer)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert :hidden = Visibility.resolve_visibility(bookshelf, {:platform_user, viewer.id})
    end

    test "viewer has blocked resource owner → :hidden" do
      owner = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
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

  describe "resolve_visibility/2 — marketplace exception" do
    test "active looking_for_home placement with profile_visibility owner → :visible for platform user" do
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
      owner = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: owner, name: "looking_for_home", visibility: "owner")

      placement =
        insert(:placement, bookshelf: bookshelf, visibility: "platform", listing_status: "active")

      viewer = insert(:user)
      {:ok, _} = Stacks.Social.block_user(owner.id, viewer.id)

      assert :hidden = Visibility.resolve_visibility(placement, {:platform_user, viewer.id})
    end
  end

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

  describe "resolve_visibility/2 — returns :hidden on error/ambiguity" do
    test "nil resource → :hidden" do
      assert :hidden = Visibility.resolve_visibility(nil, {:platform_user, Ecto.UUID.generate()})
    end

    test "unknown viewer type → :hidden" do
      book = insert(:book, visibility_tier: "public")

      assert :hidden = Visibility.resolve_visibility(book, {:unknown_viewer_type, "something"})
    end
  end

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

    test "child group under platform parent → ok (group is more restrictive than platform)" do
      assert :ok = Visibility.validate_visibility_ceiling("group", "platform", :bookshelf)
    end

    test "child platform under group parent → error (platform is more exposed than group)" do
      assert {:error, _} = Visibility.validate_visibility_ceiling("platform", "group", :bookshelf)
    end

    test "child group under owner parent → error (owner ghost-mode caps everything to owner)" do
      assert {:error, _} = Visibility.validate_visibility_ceiling("group", "owner", :bookshelf)
    end

    test "child owner under group parent → ok" do
      assert :ok = Visibility.validate_visibility_ceiling("owner", "group", :bookshelf)
    end
  end

  describe "classify_visibility_direction/2 (single ladder)" do
    test "platform → owner is a tighten (less exposed)" do
      assert :tighten = Visibility.classify_visibility_direction("platform", "owner")
    end

    test "owner → platform is a loosen (more exposed)" do
      assert :loosen = Visibility.classify_visibility_direction("owner", "platform")
    end

    test "group sits between platform and owner: group → platform is a loosen" do
      assert :loosen = Visibility.classify_visibility_direction("group", "platform")
    end

    test "platform → group is a tighten" do
      assert :tighten = Visibility.classify_visibility_direction("platform", "group")
    end

    test "no change → same" do
      assert :same = Visibility.classify_visibility_direction("platform", "platform")
    end
  end

  describe "canonical Audience level sources" do
    test "audience_levels/0 is the full stored ladder (owner/group/platform/public)" do
      assert Visibility.audience_levels() == ~w(owner group platform public)
    end

    test "profile_audience_levels/0 is owner/platform/public (group deferred to )" do
      assert Visibility.profile_audience_levels() == ~w(owner platform public)
    end

    test "valid_audience_level?/1 accepts ladder values (incl. public) and rejects others" do
      assert Visibility.valid_audience_level?("group")
      assert Visibility.valid_audience_level?("public")
      refute Visibility.valid_audience_level?("nonsense")
    end
  end

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
      resource = %{user_id: Ecto.UUID.generate()}

      assert :hidden = Visibility.resolve_visibility(resource, :unauthenticated)
    end

    test "unknown visibility falls back to check_default_visibility — owner can view" do
      owner = insert(:user, profile_visibility: "platform")
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

  describe "resolve_visibility/2 — placement profile visibility edge cases" do
    test "placement with bookshelf whose user is nil → profile ceiling defaults to owner" do
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

  describe "resolve_visibility/2 — age gate unauthenticated" do
    test "book with visibility_tier age_gated + unauthenticated → :hidden" do
      book = insert(:book, visibility_tier: "age_gated")

      assert :hidden = Visibility.resolve_visibility(book, :unauthenticated)
    end
  end

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

    test "unauthenticated viewer sees only PUBLIC bookshelves (platform is Members-only, )" do
      owner = insert(:user, profile_visibility: "public")
      _public_shelf = insert(:bookshelf, user: owner, name: "library", visibility: "public")
      _platform_shelf = insert(:bookshelf, user: owner, name: "wishlist", visibility: "platform")
      _owner_shelf = insert(:bookshelf, user: owner, name: "antilibrary", visibility: "owner")

      result = Visibility.viewable_shelves(owner.id, :unauthenticated)

      assert length(result) == 1
    end
  end

  describe "Audience proto ↔ Elixir vocabulary parity" do
    @proto_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "..",
                  "..",
                  "proto",
                  "stacks",
                  "common",
                  "v1",
                  "visibility.proto"
                ])

    defp settable_audience_values_from_proto do
      @proto_path
      |> File.read!()
      |> then(&Regex.scan(~r/^\s*AUDIENCE_(\w+)\s*=\s*\d+;/m, &1))
      |> Enum.map(fn [_, name] -> String.downcase(name) end)
      |> Enum.reject(&(&1 == "unspecified"))
    end

    test "audience_levels/0 exactly matches the proto Audience enum's settable values" do
      assert Enum.sort(Visibility.audience_levels()) ==
               Enum.sort(settable_audience_values_from_proto())
    end

    test "public is a settable value in BOTH the proto and the Elixir ladder" do
      assert "public" in settable_audience_values_from_proto()
      assert "public" in Visibility.audience_levels()
    end
  end
end
