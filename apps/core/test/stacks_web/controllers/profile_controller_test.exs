defmodule StacksWeb.ProfileControllerTest do
  @moduledoc """
  Tests for the public profile read surfaces (#213):
  GET /api/u/:handle and GET /api/u/:handle/bookshelves/:bookshelf_name.

  These assert the ENDPOINTS wire the correct (viewer, target) through the
  already-unit-tested visibility resolver — ghost/block → 404, redaction, and
  viewer-visible shelf/placement filtering. The full combinatoric matrix lives in
  the resolver unit tests + the #218 E2E.
  """
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Social

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/u/:handle" do
    test "returns a discoverable user's redacted public profile", %{conn: conn} do
      insert(:user, handle: "adalovelace", display_name: "Ada", profile_visibility: "platform")
      viewer = insert(:user)

      body =
        conn
        |> auth_conn(viewer)
        |> get("/api/u/adalovelace")
        |> json_response(200)

      assert body["handle"] == "adalovelace"
      assert body["display_name"] == "Ada"
      # REDACTED — no account/PII fields leak through the public serializer.
      refute Map.has_key?(body, "email")
      refute Map.has_key?(body, "consent_analytics")
      refute Map.has_key?(body, "role")
    end

    test "excludes bookshelves the viewer cannot see", %{conn: conn} do
      target = insert(:user, handle: "reader_x", profile_visibility: "platform")
      insert(:bookshelf, user: target, name: "library", visibility: "platform")
      insert(:bookshelf, user: target, name: "wishlist", visibility: "owner")
      viewer = insert(:user)

      body =
        conn |> auth_conn(viewer) |> get("/api/u/reader_x") |> json_response(200)

      names = Enum.map(body["bookshelves"], & &1["name"])
      assert "library" in names
      refute "wishlist" in names
    end

    test "a ghost (owner-visibility) profile is 404 to another viewer", %{conn: conn} do
      insert(:user, handle: "ghost_user", profile_visibility: "owner")
      viewer = insert(:user)

      conn |> auth_conn(viewer) |> get("/api/u/ghost_user") |> json_response(404)
    end

    test "the owner sees their own profile even when it is a ghost", %{conn: conn} do
      owner = insert(:user, handle: "myself", profile_visibility: "owner")

      body = conn |> auth_conn(owner) |> get("/api/u/myself") |> json_response(200)
      assert body["handle"] == "myself"
    end

    test "an unknown handle is 404", %{conn: conn} do
      viewer = insert(:user)
      conn |> auth_conn(viewer) |> get("/api/u/nobody_here") |> json_response(404)
    end

    test "an unauthenticated viewer can see a discoverable profile", %{conn: conn} do
      insert(:user, handle: "public_ada", profile_visibility: "platform")

      body = conn |> get("/api/u/public_ada") |> json_response(200)
      assert body["handle"] == "public_ada"
    end

    test "a blocked viewer gets 404 (indistinguishable from absent)", %{conn: conn} do
      target = insert(:user, handle: "blocker_target", profile_visibility: "platform")
      viewer = insert(:user)
      {:ok, _} = Social.block_user(target.id, viewer.id)

      conn |> auth_conn(viewer) |> get("/api/u/blocker_target") |> json_response(404)
    end
  end

  describe "GET /api/u/:handle/bookshelves/:bookshelf_name" do
    test "returns only the placements the viewer may see", %{conn: conn} do
      target = insert(:user, handle: "shelf_owner", profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: target, name: "library", visibility: "platform")
      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "platform"
      )

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "owner"
      )

      viewer = insert(:user)

      body =
        conn
        |> auth_conn(viewer)
        |> get("/api/u/shelf_owner/bookshelves/library")
        |> json_response(200)

      # The platform placement is visible; the owner-only one is filtered out.
      assert body["count"] == 1
    end

    test "an invalid bookshelf name is 404", %{conn: conn} do
      insert(:user, handle: "shelf_owner2", profile_visibility: "platform")
      viewer = insert(:user)

      conn
      |> auth_conn(viewer)
      |> get("/api/u/shelf_owner2/bookshelves/not_a_shelf")
      |> json_response(404)
    end

    test "a ghost profile's shelf is 404", %{conn: conn} do
      target = insert(:user, handle: "ghost_shelf", profile_visibility: "owner")
      insert(:bookshelf, user: target, name: "library", visibility: "platform")
      viewer = insert(:user)

      conn
      |> auth_conn(viewer)
      |> get("/api/u/ghost_shelf/bookshelves/library")
      |> json_response(404)
    end
  end

  # #213 punch items: the group-visibility and unauthenticated rows of the
  # visibility matrix, asserted on the endpoints (not just the resolver unit).
  describe "visibility matrix — group + unauthenticated" do
    test "a group-visibility shelf shows to a member and hides from a non-member (hub)", %{
      conn: conn
    } do
      owner = insert(:user, handle: "group_owner", profile_visibility: "platform")
      group = insert(:group, owner: owner)
      member = insert(:user)
      insert(:group_member, group: group, user: member)
      nonmember = insert(:user)

      insert(:bookshelf,
        user: owner,
        name: "library",
        visibility: "group",
        visibility_group_id: group.id
      )

      member_names =
        conn
        |> auth_conn(member)
        |> get("/api/u/group_owner")
        |> json_response(200)
        |> Map.get("bookshelves")
        |> Enum.map(& &1["name"])

      nonmember_names =
        conn
        |> auth_conn(nonmember)
        |> get("/api/u/group_owner")
        |> json_response(200)
        |> Map.get("bookshelves")
        |> Enum.map(& &1["name"])

      assert "library" in member_names
      refute "library" in nonmember_names
    end

    test "a group-visibility placement shows to a member and hides from a non-member (shelf)", %{
      conn: conn
    } do
      owner = insert(:user, handle: "group_shelf_owner", profile_visibility: "platform")
      group = insert(:group, owner: owner)
      member = insert(:user)
      insert(:group_member, group: group, user: member)
      nonmember = insert(:user)

      bookshelf =
        insert(:bookshelf,
          user: owner,
          name: "library",
          visibility: "platform",
          visibility_group_id: group.id
        )

      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "group"
      )

      member_count =
        conn
        |> auth_conn(member)
        |> get("/api/u/group_shelf_owner/bookshelves/library")
        |> json_response(200)
        |> Map.get("count")

      nonmember_count =
        conn
        |> auth_conn(nonmember)
        |> get("/api/u/group_shelf_owner/bookshelves/library")
        |> json_response(200)
        |> Map.get("count")

      assert member_count == 1
      assert nonmember_count == 0
    end

    test "an unauthenticated viewer sees platform placements but not owner-only ones (shelf)", %{
      conn: conn
    } do
      owner = insert(:user, handle: "unauth_shelf_owner", profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "platform"
      )

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "owner"
      )

      count =
        conn
        |> get("/api/u/unauth_shelf_owner/bookshelves/library")
        |> json_response(200)
        |> Map.get("count")

      assert count == 1
    end
  end
end
