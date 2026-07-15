defmodule StacksWeb.UserSettingsPrivacyReadControllerTest do
  @moduledoc """
  Tests for the privacy-settings read endpoint (`GET /api/settings/privacy`),
  which seeds the privacy screen with the user's saved profile visibility and
  per-shelf visibilities so a returning user sees stored values, not defaults.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/settings/privacy" do
    test "returns 401 when unauthenticated", %{conn: conn} do
      conn = get(conn, "/api/settings/privacy")
      assert json_response(conn, 401)
    end

    test "returns the current user's profile visibility and shelves", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")

      insert(:bookshelf, user: user, name: "library", visibility: "platform")
      insert(:bookshelf, user: user, name: "wishlist", visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/privacy")

      body = json_response(conn, 200)

      assert body["profile_visibility"] == "platform"

      shelves =
        body["shelves"]
        |> Enum.map(fn %{"name" => name, "visibility" => vis} -> {name, vis} end)
        |> Enum.into(%{})

      assert shelves["library"] == "platform"
      assert shelves["wishlist"] == "owner"
    end

    test "returns an empty shelf list when the user has no bookshelves", %{conn: conn} do
      user = insert(:user, profile_visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/privacy")

      body = json_response(conn, 200)
      assert body["profile_visibility"] == "owner"
      assert body["shelves"] == []
    end

    test "does not leak another user's bookshelves", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")
      other = insert(:user, profile_visibility: "platform")

      insert(:bookshelf, user: user, name: "library", visibility: "platform")
      insert(:bookshelf, user: other, name: "wishlist", visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/privacy")

      %{"shelves" => shelves} = json_response(conn, 200)

      names = Enum.map(shelves, & &1["name"])
      assert names == ["library"]
    end
  end
end
