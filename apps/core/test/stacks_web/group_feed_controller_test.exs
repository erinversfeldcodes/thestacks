defmodule StacksWeb.GroupFeedControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Social

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/groups/:id/feed" do
    test "returns 200 with data and next_cursor", %{conn: conn} do
      owner = insert(:user)
      viewer = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Feed Group", type: "close_friends"})
      insert(:group_member, group: group, user: viewer)

      bookshelf = insert(:bookshelf, user: owner)

      insert(:placement,
        bookshelf: bookshelf,
        book: insert(:book),
        visibility: "group",
        placed_at: DateTime.utc_now()
      )

      resp =
        conn
        |> auth_conn(viewer)
        |> get("/api/groups/#{group.id}/feed")
        |> json_response(200)

      assert is_list(resp["data"])
      assert length(resp["data"]) == 1
      assert Map.has_key?(resp, "next_cursor")
    end

    test "returns 403 for non-member", %{conn: conn} do
      owner = insert(:user)
      outsider = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Private", type: "close_friends"})

      conn
      |> auth_conn(outsider)
      |> get("/api/groups/#{group.id}/feed")
      |> json_response(403)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn
      |> get("/api/groups/#{Ecto.UUID.generate()}/feed")
      |> json_response(401)
    end
  end

  describe "a member with no display name" do
    # display_name is nullable; handle is not. The Elm feed decoder requires
    # user_display_name to be a string, so a single member who never set a
    # display name made the WHOLE feed fail to decode and render as empty —
    # every other member's activity included. Nothing in the schema or the
    # tests forbade the null, and dev data happened not to contain one.
    test "does not put a null name into the feed payload", %{conn: conn} do
      owner = insert(:user)
      nameless = insert(:user, display_name: nil, handle: "quiet_reader")
      {:ok, group} = Social.create_group(owner.id, %{name: "Quiet", type: "close_friends"})
      insert(:group_member, group: group, user: nameless)

      shelf = insert(:bookshelf, user: nameless)

      insert(:placement,
        bookshelf: shelf,
        book: insert(:book),
        visibility: "group",
        placed_at: DateTime.utc_now()
      )

      body =
        conn
        |> auth_conn(owner)
        |> get("/api/groups/#{group.id}/feed")
        |> json_response(200)

      assert [item] = body["data"]
      assert item["user_display_name"] == "quiet_reader"
      refute is_nil(item["user_display_name"])
    end
  end
end
