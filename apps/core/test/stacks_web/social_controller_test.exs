defmodule StacksWeb.SocialControllerTest do
  @moduledoc """
  Tests for POST /api/users/:id/block, DELETE /api/users/:id/block,
  and GET /api/settings/blocked-users.
  """

  # async: false — the :rate_limit_social test flips the global
  # `:rate_limiting_enabled` Application env and mutates the shared ETS
  # rate-limiter table, which would bleed into concurrently-running async
  # tests. Same rationale as StacksWeb.Plugs.RateLimiterTest.
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Social

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api/users/:id/block" do
    test "returns 200 when block succeeds", %{conn: conn} do
      blocker = insert(:user)
      target = insert(:user)

      conn =
        conn
        |> auth_conn(blocker)
        |> post("/api/users/#{target.id}/block")

      assert %{"blocked" => true} = json_response(conn, 200)
    end

    test "returns 404 when target user does not exist", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/users/#{Ecto.UUID.generate()}/block")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 422 when trying to block self", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/users/#{user.id}/block")

      assert %{"error" => "cannot_block_self"} = json_response(conn, 422)
    end

    test "returns 422 on duplicate block", %{conn: conn} do
      blocker = insert(:user)
      target = insert(:user)
      {:ok, _} = Social.block_user(blocker.id, target.id)

      conn =
        conn
        |> auth_conn(blocker)
        |> post("/api/users/#{target.id}/block")

      assert %{"error" => "already_blocked"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      target = insert(:user)
      conn = post(conn, "/api/users/#{target.id}/block")
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/users/:id/block" do
    test "returns 200 when unblock succeeds", %{conn: conn} do
      blocker = insert(:user)
      target = insert(:user)
      {:ok, _} = Social.block_user(blocker.id, target.id)

      conn =
        conn
        |> auth_conn(blocker)
        |> delete("/api/users/#{target.id}/block")

      assert %{"blocked" => false} = json_response(conn, 200)
    end

    test "returns 404 when no block exists", %{conn: conn} do
      user = insert(:user)
      target = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/users/#{target.id}/block")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      target = insert(:user)
      conn = delete(conn, "/api/users/#{target.id}/block")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/settings/blocked-users" do
    test "returns empty list when user has no blocks", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/blocked-users")

      assert %{"blocked_users" => [], "total" => 0} = json_response(conn, 200)
    end

    test "returns list of blocked users", %{conn: conn} do
      blocker = insert(:user)
      target = insert(:user)
      {:ok, _} = Social.block_user(blocker.id, target.id)

      conn =
        conn
        |> auth_conn(blocker)
        |> get("/api/settings/blocked-users")

      assert %{"blocked_users" => users, "total" => 1} = json_response(conn, 200)
      assert [entry] = users
      assert entry["id"] == target.id
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, "/api/settings/blocked-users")
      assert json_response(conn, 401)
    end
  end

  describe ":rate_limit_social — per-user block/unblock throttle" do
    setup do
      original = Application.get_env(:core, :rate_limiting_enabled)
      Application.put_env(:core, :rate_limiting_enabled, true)

      on_exit(fn ->
        Application.put_env(:core, :rate_limiting_enabled, original)

        if :ets.whereis(:rate_limiter) != :undefined do
          :ets.delete_all_objects(:rate_limiter)
        end
      end)

      :ok
    end

    test "returns 429 on the 21st block within the window" do
      # The :social bucket is 20 requests / 60s per authenticated user.
      blocker = insert(:user)
      targets = for _ <- 1..21, do: insert(:user)

      # The first 20 block requests succeed.
      for target <- Enum.take(targets, 20) do
        conn =
          build_conn()
          |> auth_conn(blocker)
          |> post("/api/users/#{target.id}/block")

        assert %{"blocked" => true} = json_response(conn, 200)
      end

      # The 21st request from the same user is rate limited.
      conn =
        build_conn()
        |> auth_conn(blocker)
        |> post("/api/users/#{Enum.at(targets, 20).id}/block")

      assert %{"error" => "rate_limit_exceeded"} = json_response(conn, 429)
      assert get_resp_header(conn, "retry-after") == ["60"]
    end
  end
end
