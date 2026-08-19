defmodule StacksWeb.AdminControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  defp setup_full_admin(conn) do
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

  defp get_last_audit_row do
    {:ok, %{rows: rows, columns: cols}} =
      Repo.query("SELECT * FROM audit.audit_log ORDER BY occurred_at DESC LIMIT 1")

    case List.first(rows) do
      nil -> nil
      row -> Enum.zip(cols, row) |> Map.new()
    end
  end

  describe "GET /api/admin/users/by_email" do
    test "returns user when found", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user, email: "target@example.com")

      conn = get(conn, "/api/admin/users/by_email", %{email: "target@example.com"})

      assert %{"user" => user_map} = json_response(conn, 200)
      assert user_map["id"] == target.id
      assert user_map["email"] == "target@example.com"
    end

    test "returns 404 when user not found", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)

      conn = get(conn, "/api/admin/users/by_email", %{email: "nobody@example.com"})

      assert %{"error" => "user_not_found"} = json_response(conn, 404)
    end

    test "returns 401 without admin token", %{conn: conn} do
      conn = get(conn, "/api/admin/users/by_email", %{email: "nobody@example.com"})

      assert json_response(conn, 401)
    end

    test "writes an audit row with correct fields", %{conn: conn} do
      {conn, _admin, session} = setup_full_admin(conn)
      insert(:user, email: "auditable@example.com")

      get(conn, "/api/admin/users/by_email", %{
        email: "auditable@example.com",
        reason: "testing audit"
      })

      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
      assert row["endpoint"] == "/api/admin/users/by_email"
      assert row["success"] == true
      assert row["operator_session_id"] == session.id
    end
  end

  describe "GET /api/admin/users/by_id" do
    test "returns user when found", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      conn = get(conn, "/api/admin/users/by_id", %{id: target.id})

      assert %{"user" => user_map} = json_response(conn, 200)
      assert user_map["id"] == target.id
    end

    test "returns 404 when not found", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)

      conn = get(conn, "/api/admin/users/by_id", %{id: Ecto.UUID.generate()})

      assert %{"error" => "user_not_found"} = json_response(conn, 404)
    end

    test "writes audit row", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      get(conn, "/api/admin/users/by_id", %{id: target.id})

      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
      assert row["endpoint"] == "/api/admin/users/by_id"
    end
  end

  describe "GET /api/admin/audit_log" do
    test "returns entries for user", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      Stacks.Audit.log(target.id, "test.event", resource_type: "test", metadata: %{})

      from = DateTime.add(DateTime.utc_now(), -10, :minute) |> DateTime.to_iso8601()
      to = DateTime.add(DateTime.utc_now(), 10, :minute) |> DateTime.to_iso8601()

      conn =
        get(conn, "/api/admin/audit_log", %{
          user_id: target.id,
          from: from,
          to: to
        })

      assert %{"entries" => entries} = json_response(conn, 200)
      assert is_list(entries)
      assert entries != []
    end

    test "returns 422 for invalid datetime params", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      conn =
        get(conn, "/api/admin/audit_log", %{
          user_id: target.id,
          from: "not-a-date",
          to: "also-not-a-date"
        })

      assert %{"error" => "invalid_params"} = json_response(conn, 422)
    end

    test "writes audit row", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      from = DateTime.add(DateTime.utc_now(), -10, :minute) |> DateTime.to_iso8601()
      to = DateTime.add(DateTime.utc_now(), 10, :minute) |> DateTime.to_iso8601()

      get(conn, "/api/admin/audit_log", %{user_id: target.id, from: from, to: to})

      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
      assert row["endpoint"] == "/api/admin/audit_log"
    end
  end

  describe "GET /api/admin/platform_stats" do
    test "returns stats map", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)

      conn = get(conn, "/api/admin/platform_stats")

      assert %{"stats" => stats} = json_response(conn, 200)
      assert Map.has_key?(stats, "users")
      assert Map.has_key?(stats, "books")
      assert Map.has_key?(stats, "bookshelves")
      assert Map.has_key?(stats, "placements")
      assert Map.has_key?(stats, "listings")
    end

    test "writes audit row", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)

      get(conn, "/api/admin/platform_stats")

      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
      assert row["endpoint"] == "/api/admin/platform_stats"
    end
  end

  describe "GET /api/admin/gdpr_export" do
    test "returns export data for user", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      conn = get(conn, "/api/admin/gdpr_export", %{user_id: target.id})

      assert %{"export" => _export} = json_response(conn, 200)
    end

    test "returns 404 for unknown user", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)

      conn =
        get(conn, "/api/admin/gdpr_export", %{user_id: Ecto.UUID.generate()})

      assert json_response(conn, 404)
    end

    test "writes audit row", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      get(conn, "/api/admin/gdpr_export", %{user_id: target.id})

      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
      assert row["endpoint"] == "/api/admin/gdpr_export"
    end
  end

  describe "POST /api/admin/gdpr_erase" do
    test "erases user and returns 200", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      conn =
        post(conn, "/api/admin/gdpr_erase", %{
          user_id: target.id,
          reason: "user requested erasure"
        })

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 422 when reason is missing", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      conn = post(conn, "/api/admin/gdpr_erase", %{user_id: target.id})

      assert %{"error" => "reason_required"} = json_response(conn, 422)
    end

    test "refuses a reason that names the person, since that row outlives the erasure", %{
      conn: conn
    } do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      conn =
        post(conn, "/api/admin/gdpr_erase", %{
          user_id: target.id,
          reason: "erasing at the request of jane@example.com, ticket 4417"
        })

      assert %{"error" => "reason_carries_personal_data"} = json_response(conn, 422)

      # And the erasure did NOT happen — a refused reason must not half-run.
      assert Stacks.Accounts.get_user(target.id)
    end

    test "accepts a reason that references a ticket instead of a person", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      conn =
        post(conn, "/api/admin/gdpr_erase", %{
          user_id: target.id,
          reason: "verified DSAR, ticket 4417"
        })

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 422 for unknown user_id", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)

      conn =
        post(conn, "/api/admin/gdpr_erase", %{
          user_id: Ecto.UUID.generate(),
          reason: "erasure request"
        })

      assert json_response(conn, 422)
    end

    test "writes audit row", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      post(conn, "/api/admin/gdpr_erase", %{
        user_id: target.id,
        reason: "user requested erasure"
      })

      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
      assert row["endpoint"] == "/api/admin/gdpr_erase"
    end
  end
end
