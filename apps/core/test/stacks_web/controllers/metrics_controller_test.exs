defmodule StacksWeb.MetricsControllerTest do
  @moduledoc """
  Tests for the metrics dashboard API endpoints.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  defp setup_admin_conn(conn) do
    user = insert(:owner_user)
    boot_id = Core.Application.boot_id()
    raw_ip = "127.0.0.1"
    {:ok, session} = SessionContext.create(user, raw_ip, boot_id)
    {:ok, session} = SessionContext.mark_mfa_verified(session)

    {:ok, token, _} =
      Guardian.encode_and_sign(user, %{},
        token_type: "admin",
        session_id: session.id,
        boot_id: boot_id,
        ttl: {30, :minute}
      )

    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    {conn, user, session}
  end

  defp owner_conn(conn) do
    user = insert(:owner_user)
    {:ok, token, _} = Guardian.encode_and_sign(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    {conn, user}
  end

  describe "GET /api/metrics" do
    test "returns 200 with dashboard data for admin-MFA JWT", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn = get(conn, "/api/metrics")

      assert %{"data" => data} = json_response(conn, 200)
      assert Map.has_key?(data, "system_health")
      assert Map.has_key?(data, "job_stats")
      assert Map.has_key?(data, "data_freshness")
      assert Map.has_key?(data, "costs")
      assert Map.has_key?(data, "gdpr")
      assert Map.has_key?(data, "generated_at")
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)

      conn = get(conn, "/api/metrics")

      assert conn.status == 401
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn = get(conn, "/api/metrics")

      assert conn.status == 401
    end
  end

  describe "GET /api/metrics/quality-trends" do
    test "returns 200 with quality trends for admin JWT", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn = get(conn, "/api/metrics/quality-trends")

      assert %{"data" => _data} = json_response(conn, 200)
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)

      conn = get(conn, "/api/metrics/quality-trends")

      assert conn.status == 401
    end
  end

  describe "GET /api/metrics/source-health" do
    test "returns 200 with source health for admin JWT", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn = get(conn, "/api/metrics/source-health")

      assert %{"data" => _data} = json_response(conn, 200)
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)

      conn = get(conn, "/api/metrics/source-health")

      assert conn.status == 401
    end
  end

  describe "GET /api/metrics/enrichment-gaps" do
    test "returns 200 with enrichment gaps for admin JWT", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn = get(conn, "/api/metrics/enrichment-gaps")

      assert %{"data" => _data} = json_response(conn, 200)
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)

      conn = get(conn, "/api/metrics/enrichment-gaps")

      assert conn.status == 401
    end
  end
end
