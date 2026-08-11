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

    test "a null display_name is serialized as an empty string, not null", %{conn: conn} do
      insert(:user, handle: "nameless", display_name: nil, profile_visibility: "platform")
      viewer = insert(:user)

      body = conn |> auth_conn(viewer) |> get("/api/u/nameless") |> json_response(200)
      assert body["display_name"] == ""
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

    test "an unauthenticated viewer can see a PUBLIC profile", %{conn: conn} do
      insert(:user, handle: "public_ada", profile_visibility: "public")

      body = conn |> get("/api/u/public_ada") |> json_response(200)
      assert body["handle"] == "public_ada"
    end

    test "an unauthenticated viewer gets 404 for a platform (Members) profile (#225)", %{
      conn: conn
    } do
      insert(:user, handle: "members_ada", profile_visibility: "platform")

      conn |> get("/api/u/members_ada") |> json_response(404)
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

    test "an unauthenticated viewer sees public placements but not owner-only ones (shelf, #225)",
         %{
           conn: conn
         } do
      owner = insert(:user, handle: "unauth_shelf_owner", profile_visibility: "public")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "public")
      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "public"
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

    test "a signed-in non-member sees platform (Members) placements but an anon viewer does not (#225)",
         %{conn: conn} do
      owner = insert(:user, handle: "members_shelf_owner", profile_visibility: "public")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "public")
      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "platform"
      )

      count_for = fn conn ->
        conn
        |> get("/api/u/members_shelf_owner/bookshelves/library")
        |> json_response(200)
        |> Map.get("count")
      end

      assert count_for.(auth_conn(conn, insert(:user))) == 1
      assert count_for.(conn) == 0
    end

    test "an age-gated book is hidden from unverified/unauthenticated viewers, shown to verified",
         %{
           conn: conn
         } do
      owner = insert(:user, handle: "age_owner", profile_visibility: "public")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "public")
      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book, visibility_tier: "age_gated"),
        visibility: "public"
      )

      count_for = fn conn ->
        conn
        |> get("/api/u/age_owner/bookshelves/library")
        |> json_response(200)
        |> Map.get("count")
      end

      assert count_for.(auth_conn(conn, insert(:user, age_verified: true))) == 1
      assert count_for.(auth_conn(conn, insert(:user, age_verified: false))) == 0
      assert count_for.(conn) == 0
    end

    test "the owner sees their own age-gated book even when unverified", %{conn: conn} do
      owner =
        insert(:user, handle: "age_self", profile_visibility: "platform", age_verified: false)

      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book, visibility_tier: "age_gated"),
        visibility: "platform"
      )

      count =
        conn
        |> auth_conn(owner)
        |> get("/api/u/age_self/bookshelves/library")
        |> json_response(200)
        |> Map.get("count")

      assert count == 1
    end
  end

  describe "marketplace exception — looking_for_home shelf endpoint (#226)" do
    setup %{conn: conn} do
      owner = insert(:user, handle: "lfh_owner", profile_visibility: "public")

      bookshelf =
        insert(:bookshelf, user: owner, name: "looking_for_home", visibility: "public")

      shelf = insert(:shelf, bookshelf: bookshelf)

      insert(:placement,
        bookshelf: bookshelf,
        shelf: shelf,
        book: insert(:book),
        visibility: "owner",
        listing_status: "active"
      )

      count_for = fn c ->
        c
        |> get("/api/u/lfh_owner/bookshelves/looking_for_home")
        |> json_response(200)
        |> Map.get("count")
      end

      %{conn: conn, owner: owner, count_for: count_for}
    end

    test "a signed-in (platform) viewer sees the actively-listed owner-rung placement",
         %{conn: conn, count_for: count_for} do
      assert count_for.(auth_conn(conn, insert(:user))) == 1
    end

    test "an anonymous viewer does NOT get the marketplace punch", %{count_for: count_for} do
      assert count_for.(build_conn()) == 0
    end

    test "a blocked viewer does not see it — block beats the marketplace exception (SEC-2)",
         %{conn: conn, owner: owner} do
      blocked = insert(:user)
      {:ok, _} = Stacks.Social.block_user(owner.id, blocked.id)

      conn
      |> auth_conn(blocked)
      |> get("/api/u/lfh_owner/bookshelves/looking_for_home")
      |> json_response(404)
    end
  end

  describe "public browse bounding + O(1) shared-gate queries (#221)" do
    test "the public response is hard-capped while the owner's own view is not", %{conn: conn} do
      prev = Application.get_env(:core, :public_shelf_cap)
      Application.put_env(:core, :public_shelf_cap, 2)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:core, :public_shelf_cap)
          value -> Application.put_env(:core, :public_shelf_cap, value)
        end
      end)

      owner = insert(:user, handle: "bounded_owner", profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
      shelf = insert(:shelf, bookshelf: bookshelf)

      for _ <- 1..5 do
        insert(:placement,
          bookshelf: bookshelf,
          shelf: shelf,
          book: insert(:book),
          visibility: "platform"
        )
      end

      viewer = insert(:user)

      body =
        conn
        |> auth_conn(viewer)
        |> get("/api/u/bounded_owner/bookshelves/library")
        |> json_response(200)

      returned = body["shelves"] |> Enum.flat_map(& &1["placements"]) |> length()
      assert body["count"] == 2
      assert returned == 2

      owner_body =
        conn
        |> auth_conn(owner)
        |> get("/api/bookshelves/library")
        |> json_response(200)

      assert owner_body["count"] == 5
    end

    test "per-request query count is independent of placement count", %{conn: conn} do
      viewer = insert(:user)

      seed_shelf = fn handle, n ->
        owner = insert(:user, handle: handle, profile_visibility: "platform")
        bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
        shelf = insert(:shelf, bookshelf: bookshelf)

        for _ <- 1..n do
          insert(:placement,
            bookshelf: bookshelf,
            shelf: shelf,
            book: insert(:book),
            visibility: "platform"
          )
        end

        handle
      end

      small = seed_shelf.("qcount_small", 1)
      large = seed_shelf.("qcount_large", 20)

      browse = fn handle ->
        with_query_count(fn ->
          conn
          |> auth_conn(viewer)
          |> get("/api/u/#{handle}/bookshelves/library")
          |> json_response(200)
        end)
      end

      {small_body, small_q} = browse.(small)
      {large_body, large_q} = browse.(large)

      assert small_body["count"] == 1
      assert large_body["count"] == 20
      assert large_q == small_q
    end
  end

  defp with_query_count(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {:qcount, ref}

    :telemetry.attach(
      handler_id,
      [:core, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, {ref, :query})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_query_count(ref, 0)}
  end

  defp drain_query_count(ref, acc) do
    receive do
      {^ref, :query} -> drain_query_count(ref, acc + 1)
    after
      0 -> acc
    end
  end

  describe "has_feed on each bookshelf summary (G4)" do
    test "true for a platform-visible bookshelf", %{conn: conn} do
      target = insert(:user, handle: "feedreader", profile_visibility: "platform")
      insert(:bookshelf, user: target, name: "library", visibility: "platform")
      viewer = insert(:user)

      body = conn |> auth_conn(viewer) |> get("/api/u/feedreader") |> json_response(200)

      assert [%{"name" => "library", "has_feed" => true}] = body["bookshelves"]
    end

    test "true for a public bookshelf — the flag tracks the feed, not one visibility string" do
      target = insert(:user, handle: "public_reader", profile_visibility: "platform")
      shelf = insert(:bookshelf, user: target, name: "library", visibility: "public")
      viewer = insert(:user)

      body =
        build_conn() |> auth_conn(viewer) |> get("/api/u/public_reader") |> json_response(200)

      assert [%{"name" => "library", "has_feed" => true}] = body["bookshelves"],
             "a public bookshelf was advertised as having no feed: " <>
               inspect(body["bookshelves"])

      feed = build_conn() |> get("/api/feeds/u/public_reader/library")
      assert response(feed, 200)
      assert shelf.visibility == "public"
    end

    test "false for a group-visible bookshelf the viewer can see", %{conn: conn} do
      owner = insert(:user, handle: "group_reader", profile_visibility: "platform")
      group = insert(:group, owner: owner)
      member = insert(:user)
      insert(:group_member, group: group, user: member)

      insert(:bookshelf,
        user: owner,
        name: "library",
        visibility: "group",
        visibility_group_id: group.id
      )

      body = conn |> auth_conn(member) |> get("/api/u/group_reader") |> json_response(200)

      assert [%{"name" => "library", "has_feed" => false}] = body["bookshelves"],
             "a group-visible shelf was advertised as having a feed: " <>
               inspect(body["bookshelves"])
    end

    test "the payload does not leak the visibility tier itself", %{conn: conn} do
      target = insert(:user, handle: "discreet", profile_visibility: "platform")
      insert(:bookshelf, user: target, name: "library", visibility: "platform")
      viewer = insert(:user)

      body = conn |> auth_conn(viewer) |> get("/api/u/discreet") |> json_response(200)
      [shelf] = body["bookshelves"]

      assert Map.has_key?(shelf, "has_feed")

      refute Map.has_key?(shelf, "visibility"),
             "the public profile payload now exposes the visibility ladder"
    end
  end
end
