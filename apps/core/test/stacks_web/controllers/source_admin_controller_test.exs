defmodule StacksWeb.SourceAdminControllerTest do
  @moduledoc """
      Tests for the source approval admin API endpoints.
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

  describe "GET /api/admin/sources" do
    test "returns paginated list of sources for admin JWT", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      insert(:discovered_source, status: "pending_review")
      insert(:discovered_source, status: "approved")

      conn = get(conn, "/api/admin/sources")

      assert %{"sources" => sources, "total" => 2, "page" => 1} = json_response(conn, 200)
      assert length(sources) == 2
    end

    test "filters by status", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      insert(:discovered_source, status: "pending_review")
      insert(:discovered_source, status: "approved", approved_at: DateTime.utc_now())

      conn = get(conn, "/api/admin/sources", %{"status" => "pending_review"})

      assert %{"sources" => sources, "total" => 1} = json_response(conn, 200)
      assert length(sources) == 1
      assert hd(sources)["status"] == "pending_review"
    end

    test "filters by type", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      insert(:discovered_source, type: "bookshop")
      insert(:discovered_source, type: "review_site")

      conn = get(conn, "/api/admin/sources", %{"type" => "bookshop"})

      assert %{"sources" => sources, "total" => 1} = json_response(conn, 200)
      assert hd(sources)["type"] == "bookshop"
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)

      conn = get(conn, "/api/admin/sources")

      assert conn.status == 401
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn = get(conn, "/api/admin/sources")
      assert conn.status == 401
    end
  end

  describe "PUT /api/admin/sources/:id/approve" do
    test "transitions pending_review to approved", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      source = insert(:discovered_source, status: "pending_review")

      conn = put(conn, "/api/admin/sources/#{source.id}/approve")

      assert %{"source" => result} = json_response(conn, 200)
      assert result["id"] == source.id
      assert result["status"] == "approved"
      assert result["approved_at"] != nil
    end

    test "returns 422 for already approved source", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      source = insert(:discovered_source, status: "approved", approved_at: DateTime.utc_now())

      conn = put(conn, "/api/admin/sources/#{source.id}/approve")

      assert %{"error" => "invalid state transition"} = json_response(conn, 422)
    end

    test "returns 404 for nonexistent source", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn = put(conn, "/api/admin/sources/#{Ecto.UUID.generate()}/approve")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)
      source = insert(:discovered_source, status: "pending_review")

      conn = put(conn, "/api/admin/sources/#{source.id}/approve")

      assert conn.status == 401
    end
  end

  describe "PUT /api/admin/sources/:id/reject" do
    test "transitions pending_review to dismissed", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      source = insert(:discovered_source, status: "pending_review")

      conn = put(conn, "/api/admin/sources/#{source.id}/reject")

      assert %{"source" => result} = json_response(conn, 200)
      assert result["id"] == source.id
      assert result["status"] == "dismissed"
    end

    test "returns 422 for already dismissed source", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      source = insert(:discovered_source, status: "dismissed")

      conn = put(conn, "/api/admin/sources/#{source.id}/reject")

      assert %{"error" => "invalid state transition"} = json_response(conn, 422)
    end

    test "returns 404 for nonexistent source", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn = put(conn, "/api/admin/sources/#{Ecto.UUID.generate()}/reject")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)
      source = insert(:discovered_source, status: "pending_review")

      conn = put(conn, "/api/admin/sources/#{source.id}/reject")

      assert conn.status == 401
    end
  end

  describe "GET /api/admin/source-health" do
    test "returns per-source health under a data envelope for admin JWT", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      insert(:source_health_check,
        source_name: "openlibrary-covers",
        source_type: "scraper_config",
        status: "healthy",
        consecutive_failures: 0,
        last_success_at: DateTime.utc_now(),
        last_failure_at: nil
      )

      conn = get(conn, "/api/admin/source-health")

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["name"] == "openlibrary-covers"
      assert row["source_type"] == "scraper_config"
      assert row["status"] == "healthy"
      assert row["consecutive_failures"] == 0
      assert is_binary(row["last_success_at"])
      assert row["last_failure_at"] == nil
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)

      conn = get(conn, "/api/admin/source-health")

      assert conn.status == 401
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn = get(conn, "/api/admin/source-health")
      assert conn.status == 401
    end
  end
end
