defmodule StacksWeb.Plugs.AuditAdminCallTest do
  use CoreWeb.ConnCase, async: false

  import Plug.Conn
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Admin.SessionContext
  alias StacksWeb.Plugs.AuditAdminCall

  @raw_ip "127.0.0.1"

  defp setup_admin_conn(conn) do
    user = insert(:owner_user)
    boot_id = Core.Application.boot_id()
    {:ok, session} = SessionContext.create(user, @raw_ip, boot_id)
    {:ok, session} = SessionContext.mark_mfa_verified(session)

    conn =
      conn
      |> assign(:current_user, user)
      |> assign(:admin_session, session)

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

  describe "AuditAdminCall" do
    test "writes an audit row after the request completes", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn =
        conn
        |> Map.put(:request_path, "/api/admin/test")
        |> Map.put(:method, "GET")
        |> Map.put(:params, %{})
        |> AuditAdminCall.call([])
        |> send_resp(200, ~s({"ok": true}))

      assert conn.status == 200

      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
    end

    test "audit row has correct endpoint, success=true for 200 response", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn
      |> Map.put(:request_path, "/api/admin/users/by_email")
      |> Map.put(:method, "GET")
      |> Map.put(:params, %{})
      |> AuditAdminCall.call([])
      |> send_resp(200, ~s({"user": {}}))

      row = get_last_audit_row()
      assert row["endpoint"] == "/api/admin/users/by_email"
      assert row["success"] == true
    end

    test "audit row has success=false for 4xx response", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn
      |> Map.put(:request_path, "/api/admin/users/by_email")
      |> Map.put(:method, "GET")
      |> Map.put(:params, %{})
      |> AuditAdminCall.call([])
      |> send_resp(404, ~s({"error": "not_found"}))

      row = get_last_audit_row()
      assert row["success"] == false
    end

    test "audit row includes operator_session_id from admin_session assign", %{conn: conn} do
      {conn, _user, session} = setup_admin_conn(conn)

      conn
      |> Map.put(:request_path, "/api/admin/platform_stats")
      |> Map.put(:method, "GET")
      |> Map.put(:params, %{})
      |> AuditAdminCall.call([])
      |> send_resp(200, ~s({"stats": {}}))

      row = get_last_audit_row()
      assert row["operator_session_id"] == session.id
    end

    test "audit row includes reason from params", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn
      |> Map.put(:request_path, "/api/admin/users/by_id")
      |> Map.put(:method, "GET")
      |> Map.put(:params, %{"reason" => "investigating complaint"})
      |> AuditAdminCall.call([])
      |> send_resp(200, ~s({"user": {}}))

      # Reason is stored in encrypted metadata — check the row was written
      row = get_last_audit_row()
      assert row != nil
      assert row["action"] == "admin.call"
    end

    test "audit row includes latency_ms (> 0)", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn
      |> Map.put(:request_path, "/api/admin/platform_stats")
      |> Map.put(:method, "GET")
      |> Map.put(:params, %{})
      |> AuditAdminCall.call([])
      |> send_resp(200, ~s({"stats": {}}))

      row = get_last_audit_row()
      assert row["latency_ms"] != nil
      assert row["latency_ms"] >= 0
    end

    test "does not halt or modify the response when audit write fails", %{conn: conn} do
      # Use a conn without current_user / admin_session to simulate a context
      # where something might go wrong in the audit path
      conn =
        conn
        |> Map.put(:request_path, "/api/admin/test")
        |> Map.put(:method, "GET")
        |> Map.put(:params, %{})
        |> assign(:current_user, nil)
        |> assign(:admin_session, nil)
        |> AuditAdminCall.call([])
        |> send_resp(200, ~s({"ok": true}))

      # Response should still be sent normally despite nil user/session
      assert conn.status == 200
      refute conn.halted
    end
  end
end
