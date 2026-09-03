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

  describe "POST /api/admin/degraded_accounts/restore" do
    test "restores the account and records WHO reached into it", %{conn: conn} do
      # Through the real endpoint and the real :admin pipeline.
      #
      # The context-level test for this used to call `Stacks.Audit.log` ITSELF
      # and then assert the row existed — so deleting the controller's audit call
      # left it green. The guarantee the runbook depends on ("un-degrading an
      # account without a trace would be worse than the lockout it fixes") was
      # unenforced by anything.
      {conn, admin, _session} = setup_full_admin(conn)

      target =
        insert(:user,
          email_confirmed: false,
          pending_email: "new@example.com",
          pending_email_token: "tok",
          pending_email_sent_at: DateTime.add(DateTime.utc_now(), -40, :day),
          pending_email_revert_token: "revert-tok"
        )

      conn = post(conn, "/api/admin/degraded_accounts/restore", %{user_id: target.id})
      assert %{"ok" => true} = json_response(conn, 200)

      %{rows: rows} =
        Core.Repo.query!(
          "SELECT user_id, resource_id FROM audit.audit_log WHERE action = $1",
          ["admin.account_restored"]
        )

      assert [[actor, subject]] = rows
      assert Ecto.UUID.cast!(actor) == admin.id, "the audit row must name the OPERATOR"
      assert Ecto.UUID.cast!(subject) == target.id, "and the account they reached into"
    end

    test "404s an unknown user", %{conn: conn} do
      {conn, _admin, _session} = setup_full_admin(conn)
      conn = post(conn, "/api/admin/degraded_accounts/restore", %{user_id: Ecto.UUID.generate()})
      assert %{"error" => "user_not_found"} = json_response(conn, 404)
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

    test "the refused reason is not stored by the audit plug on the way out", %{conn: conn} do
      {conn, admin, _session} = setup_full_admin(conn)
      target = insert(:user)

      post(conn, "/api/admin/gdpr_erase", %{
        user_id: target.id,
        reason: "erasing at the request of jane@example.com, ticket 4417"
      })

      # The controller refuses this reason precisely because an audit row
      # outlives the erasure it authorises. The admin-call plug writes
      # `conn.params["reason"]` into that same audit row from a
      # `register_before_send` hook — which still runs on the 422. A guard that
      # refuses the data and then stores it anyway has guarded nothing.
      {entries, _total, _page, _per_page} = Stacks.Audit.list_for_user(admin.id)

      leaked =
        entries
        |> Enum.flat_map(fn e -> [e.metadata[:reason], e.metadata["reason"]] end)
        |> Enum.filter(&is_binary/1)

      refute Enum.any?(leaked, &String.contains?(&1, "jane@example.com")),
             "the audit metadata kept the address the guard refused: #{inspect(leaked)}"
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
