defmodule StacksWeb.Plugs.RequireConfirmedEmailTest do
  @moduledoc """
    Tests for `StacksWeb.Plugs.RequireConfirmedEmail`.

    The plug is a defence-in-depth gate in the authenticated pipeline: even if a
    JWT is issued for a user whose email is not confirmed, every protected request
    must be rejected with 403 until the address is confirmed.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias StacksWeb.Plugs.RequireConfirmedEmail

  describe "call/2 (plug unit)" do
    test "403s an authenticated user whose email is not confirmed" do
      user = insert(:user, email_confirmed: false)

      conn =
        build_conn()
        |> Guardian.Plug.put_current_resource(user)
        |> RequireConfirmedEmail.call(RequireConfirmedEmail.init([]))

      assert conn.halted
      assert %{"error" => "email not confirmed"} = json_response(conn, 403)
    end

    test "passes an authenticated user whose email is confirmed" do
      user = insert(:user, email_confirmed: true)

      conn =
        build_conn()
        |> Guardian.Plug.put_current_resource(user)
        |> RequireConfirmedEmail.call(RequireConfirmedEmail.init([]))

      refute conn.halted
    end
  end

  describe "protected route enforcement (HTTP)" do
    test "an authenticated request from an unconfirmed user is 403'd on a protected route",
         %{conn: conn} do
      user = insert(:user, email_confirmed: false)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert %{"error" => "email not confirmed"} = json_response(conn, 403)
    end

    test "a confirmed user reaches the protected route", %{conn: conn} do
      user = insert(:user, email_confirmed: true)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert json_response(conn, 200)
    end
  end
end
