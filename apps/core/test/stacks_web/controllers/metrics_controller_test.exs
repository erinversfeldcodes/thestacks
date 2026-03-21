defmodule StacksWeb.MetricsControllerTest do
  @moduledoc """
  Tests for the metrics dashboard API endpoints.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/metrics" do
    test "returns 200 with dashboard data for owner user", %{conn: conn} do
      user = insert(:owner_user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics")

      assert %{"data" => data} = json_response(conn, 200)
      assert Map.has_key?(data, "system_health")
      assert Map.has_key?(data, "job_stats")
      assert Map.has_key?(data, "data_freshness")
      assert Map.has_key?(data, "costs")
      assert Map.has_key?(data, "gdpr")
      assert Map.has_key?(data, "generated_at")
    end

    test "returns 403 for regular user", %{conn: conn} do
      user = insert(:user, role: "user")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics")

      assert %{"error" => error} = json_response(conn, 403)
      assert String.contains?(error, "owner")
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn = get(conn, "/api/metrics")

      assert conn.status == 401
    end
  end

  describe "GET /api/metrics/quality-trends" do
    test "returns 200 with quality trends for owner", %{conn: conn} do
      user = insert(:owner_user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics/quality-trends")

      assert %{"data" => _data} = json_response(conn, 200)
    end

    test "returns 403 for regular user", %{conn: conn} do
      user = insert(:user, role: "user")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics/quality-trends")

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/metrics/source-health" do
    test "returns 200 with source health for owner", %{conn: conn} do
      user = insert(:owner_user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics/source-health")

      assert %{"data" => _data} = json_response(conn, 200)
    end

    test "returns 403 for regular user", %{conn: conn} do
      user = insert(:user, role: "user")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics/source-health")

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/metrics/enrichment-gaps" do
    test "returns 200 with enrichment gaps for owner", %{conn: conn} do
      user = insert(:owner_user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics/enrichment-gaps")

      assert %{"data" => _data} = json_response(conn, 200)
    end

    test "returns 403 for regular user", %{conn: conn} do
      user = insert(:user, role: "user")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/metrics/enrichment-gaps")

      assert json_response(conn, 403)
    end
  end
end
