defmodule StacksWeb.GroupControllerTest do
  @moduledoc "Tests for GroupController and GroupMemberController endpoints."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api/groups" do
    test "creates a group (201)", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/groups", %{name: "Book Club", type: "close_friends"})

      assert %{"group" => group} = json_response(conn, 201)
      assert group["name"] == "Book Club"
      assert group["type"] == "close_friends"
      assert group["owner_id"] == user.id
    end

    test "returns 422 for empty name", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/groups", %{name: "", type: "close_friends"})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["name"]
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = post(conn, "/api/groups", %{name: "Test", type: "close_friends"})
      assert conn.status == 401
    end
  end

  describe "GET /api/groups/:id" do
    test "returns group for member (200)", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner, visibility: "invite_only")
      insert(:group_member, group: group, user: owner)

      conn =
        conn
        |> auth_conn(owner)
        |> get("/api/groups/#{group.id}")

      assert %{"group" => data} = json_response(conn, 200)
      assert data["id"] == group.id
    end

    test "returns platform-visible group for non-member (200)", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner, visibility: "platform")
      viewer = insert(:user)

      conn =
        conn
        |> auth_conn(viewer)
        |> get("/api/groups/#{group.id}")

      assert %{"group" => data} = json_response(conn, 200)
      assert data["id"] == group.id
    end

    test "returns 404 for invite-only group non-member", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner, visibility: "invite_only")
      viewer = insert(:user)

      conn =
        conn
        |> auth_conn(viewer)
        |> get("/api/groups/#{group.id}")

      assert json_response(conn, 404)
    end

    test "returns 404 for non-existent group", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/groups/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/groups/#{Ecto.UUID.generate()}")
      assert conn.status == 401
    end
  end

  describe "POST /api/groups/:group_id/invitations" do
    test "creates invitation (201)", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      invitee = insert(:user)

      conn =
        conn
        |> auth_conn(owner)
        |> post("/api/groups/#{group.id}/invitations", %{identifier: invitee.email})

      assert %{"invitation" => inv} = json_response(conn, 201)
      assert inv["group_id"] == group.id
      assert inv["invited_user_id"] == invitee.id
    end

    test "returns 403 for non-member inviter", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      non_member = insert(:user)
      invitee = insert(:user)

      conn =
        conn
        |> auth_conn(non_member)
        |> post("/api/groups/#{group.id}/invitations", %{identifier: invitee.email})

      assert json_response(conn, 403)
    end

    test "returns 422 for already_member", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      member = insert(:user)
      insert(:group_member, group: group, user: member)

      conn =
        conn
        |> auth_conn(owner)
        |> post("/api/groups/#{group.id}/invitations", %{identifier: member.email})

      assert json_response(conn, 422)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = post(conn, "/api/groups/#{Ecto.UUID.generate()}/invitations", %{identifier: "x"})
      assert conn.status == 401
    end
  end

  describe "POST /api/groups/:group_id/invitations/:id/accept" do
    test "accepts invitation (200)", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      invitee = insert(:user)

      invitation =
        insert(:group_invitation, group: group, invited_by_user: owner, invited_user: invitee)

      conn =
        conn
        |> auth_conn(invitee)
        |> post("/api/groups/#{group.id}/invitations/#{invitation.id}/accept")

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 403 for wrong user", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      invitee = insert(:user)

      invitation =
        insert(:group_invitation, group: group, invited_by_user: owner, invited_user: invitee)

      other = insert(:user)

      conn =
        conn
        |> auth_conn(other)
        |> post("/api/groups/#{group.id}/invitations/#{invitation.id}/accept")

      assert json_response(conn, 403)
    end

    test "returns 404 for non-existent invitation", %{conn: conn} do
      user = insert(:user)
      group = insert(:group, owner: user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/groups/#{group.id}/invitations/#{Ecto.UUID.generate()}/accept")

      assert json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        post(
          conn,
          "/api/groups/#{Ecto.UUID.generate()}/invitations/#{Ecto.UUID.generate()}/accept"
        )

      assert conn.status == 401
    end
  end

  describe "POST /api/groups/:group_id/invitations/:id/decline" do
    test "declines invitation (200)", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      invitee = insert(:user)

      invitation =
        insert(:group_invitation, group: group, invited_by_user: owner, invited_user: invitee)

      conn =
        conn
        |> auth_conn(invitee)
        |> post("/api/groups/#{group.id}/invitations/#{invitation.id}/decline")

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 403 for wrong user", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      invitee = insert(:user)

      invitation =
        insert(:group_invitation, group: group, invited_by_user: owner, invited_user: invitee)

      other = insert(:user)

      conn =
        conn
        |> auth_conn(other)
        |> post("/api/groups/#{group.id}/invitations/#{invitation.id}/decline")

      assert json_response(conn, 403)
    end

    test "returns 404 for non-existent invitation", %{conn: conn} do
      user = insert(:user)
      group = insert(:group, owner: user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/groups/#{group.id}/invitations/#{Ecto.UUID.generate()}/decline")

      assert json_response(conn, 404)
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn =
        post(
          conn,
          "/api/groups/#{Ecto.UUID.generate()}/invitations/#{Ecto.UUID.generate()}/decline"
        )

      assert json_response(conn, 401)
    end
  end

  describe "GET /api/groups/:group_id/members" do
    test "lists the group's members with names, not raw ids", %{conn: conn} do
      owner = insert(:user, display_name: "Ada")
      group = insert(:group, owner: owner, visibility: "platform")
      insert(:group_member, group: group, user: owner, role: "owner")
      member = insert(:user, display_name: "Grace")
      insert(:group_member, group: group, user: member)

      conn =
        conn
        |> auth_conn(owner)
        |> get("/api/groups/#{group.id}/members")

      assert %{"members" => members} = json_response(conn, 200)
      names = Enum.map(members, & &1["display_name"]) |> Enum.sort()

      # The whole point: the members tab could only ever show the owner's UUID
      # before, because this endpoint had no route.
      assert names == ["Ada", "Grace"]
      assert Enum.any?(members, &(&1["role"] == "owner"))
    end

    test "an invite-only group is not readable by a non-member", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner, visibility: "invite_only")
      insert(:group_member, group: group, user: owner, role: "owner")
      outsider = insert(:user)

      conn =
        conn
        |> auth_conn(outsider)
        |> get("/api/groups/#{group.id}/members")

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/groups/:group_id/members/:user_id" do
    test "owner removes member (204)", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      member = insert(:user)
      insert(:group_member, group: group, user: member)

      conn =
        conn
        |> auth_conn(owner)
        |> delete("/api/groups/#{group.id}/members/#{member.id}")

      assert response(conn, 204) == ""
    end

    test "returns 403 for non-owner", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      member = insert(:user)
      insert(:group_member, group: group, user: member)
      other_member = insert(:user)
      insert(:group_member, group: group, user: other_member)

      conn =
        conn
        |> auth_conn(member)
        |> delete("/api/groups/#{group.id}/members/#{other_member.id}")

      assert json_response(conn, 403)
    end

    test "returns 404 for non-member target", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      non_member = insert(:user)

      conn =
        conn
        |> auth_conn(owner)
        |> delete("/api/groups/#{group.id}/members/#{non_member.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = delete(conn, "/api/groups/#{Ecto.UUID.generate()}/members/#{Ecto.UUID.generate()}")
      assert conn.status == 401
    end
  end

  describe "DELETE /api/groups/:group_id/leave" do
    test "member leaves (204)", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)
      member = insert(:user)
      insert(:group_member, group: group, user: member)

      conn =
        conn
        |> auth_conn(member)
        |> delete("/api/groups/#{group.id}/leave")

      assert response(conn, 204) == ""
    end

    test "returns 422 for owner trying to leave", %{conn: conn} do
      owner = insert(:user)
      group = insert(:group, owner: owner)
      insert(:group_member, group: group, user: owner)

      conn =
        conn
        |> auth_conn(owner)
        |> delete("/api/groups/#{group.id}/leave")

      assert %{"error" => "cannot leave as owner"} = json_response(conn, 422)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = delete(conn, "/api/groups/#{Ecto.UUID.generate()}/leave")
      assert conn.status == 401
    end
  end
end
