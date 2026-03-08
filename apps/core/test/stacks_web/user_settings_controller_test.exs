defmodule StacksWeb.UserSettingsControllerTest do
  @moduledoc """
  Tests for PUT /api/settings/age_verification.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "PUT /api/settings/age_verification" do
    test "returns 200 and sets age_verified to true", %{conn: conn} do
      user = insert(:user, age_verified: false)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/age_verification", %{age_verified: true})

      assert %{"age_verified" => true} = json_response(conn, 200)
    end

    test "returns 200 and sets age_verified to false", %{conn: conn} do
      user = insert(:user, age_verified: true)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/age_verification", %{age_verified: false})

      assert %{"age_verified" => false} = json_response(conn, 200)
    end

    test "returns 422 when age_verified parameter is missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/age_verification", %{})

      assert %{"error" => "age_verified parameter is required and must be a boolean"} =
               json_response(conn, 422)
    end

    test "returns 422 when age_verified is not a boolean", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/age_verification", %{age_verified: "yes"})

      assert %{"error" => "age_verified parameter is required and must be a boolean"} =
               json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/settings/age_verification", %{age_verified: true})
      assert json_response(conn, 401)
    end
  end
end
