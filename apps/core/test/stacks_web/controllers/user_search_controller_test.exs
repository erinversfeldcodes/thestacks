defmodule StacksWeb.UserSearchControllerTest do
  @moduledoc """
  Tests for the people-search endpoint (#217): GET /api/search/users?q=<term>.

  Runs under `:optional_auth`. Asserts the endpoint returns the redacted
  `public_profile_summary` shape and that ghost/blocked exclusion (enforced in
  `Accounts.search_users/2` SQL) reaches the wire — a ghost or blocked user
  never appears in the JSON result set.
  """
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Social

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/search/users" do
    test "returns discoverable readers matching the term as redacted summaries", %{conn: conn} do
      insert(:user, handle: "adal", display_name: "Ada Lovelace", profile_visibility: "platform")
      viewer = insert(:user)

      body =
        conn
        |> auth_conn(viewer)
        |> get("/api/search/users", q: "Ada")
        |> json_response(200)

      assert [user] = body["users"]
      assert user["handle"] == "adal"
      assert user["display_name"] == "Ada Lovelace"
      # REDACTED — no account/PII fields leak.
      refute Map.has_key?(user, "email")
      refute Map.has_key?(user, "consent_analytics")
      refute Map.has_key?(user, "role")
    end

    test "returns an empty list when nothing matches", %{conn: conn} do
      insert(:user, display_name: "Grace Hopper", profile_visibility: "platform")
      viewer = insert(:user)

      body =
        conn |> auth_conn(viewer) |> get("/api/search/users", q: "Zzz") |> json_response(200)

      assert body["users"] == []
    end

    test "excludes a ghost (owner-visibility) from the result set", %{conn: conn} do
      insert(:user, display_name: "Ada Ghost", profile_visibility: "owner")
      viewer = insert(:user)

      body =
        conn |> auth_conn(viewer) |> get("/api/search/users", q: "Ada") |> json_response(200)

      assert body["users"] == []
    end

    test "excludes a blocked user (either direction)", %{conn: conn} do
      viewer = insert(:user, profile_visibility: "platform")
      blocked = insert(:user, display_name: "Ada Blocked", profile_visibility: "platform")
      {:ok, _} = Social.block_user(viewer.id, blocked.id)

      body =
        conn |> auth_conn(viewer) |> get("/api/search/users", q: "Ada") |> json_response(200)

      assert body["users"] == []
    end

    test "unauthenticated request still excludes ghosts but returns platform users", %{conn: conn} do
      insert(:user, handle: "seen", display_name: "Ada Platform", profile_visibility: "platform")
      insert(:user, display_name: "Ada Ghost", profile_visibility: "owner")

      body = conn |> get("/api/search/users", q: "Ada") |> json_response(200)

      assert [user] = body["users"]
      assert user["handle"] == "seen"
    end

    test "a missing q param yields an empty result", %{conn: conn} do
      insert(:user, display_name: "Ada Lovelace", profile_visibility: "platform")

      body = conn |> get("/api/search/users") |> json_response(200)

      assert body["users"] == []
    end
  end
end
