defmodule StacksWeb.PartnerControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.Partners

  @valid_reg %{
    name: "Booked Up",
    business_type: "bookshop",
    contact_email: "hi@bookedup.com"
  }

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

  defp user_conn(conn) do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api/partners/register" do
    test "creates partner (201)", %{conn: conn} do
      conn = post(conn, "/api/partners/register", @valid_reg)
      assert %{"partner" => p} = json_response(conn, 201)
      assert p["status"] == "pending"
    end

    test "returns 422 for missing name", %{conn: conn} do
      conn =
        post(conn, "/api/partners/register", %{
          business_type: "bookshop",
          contact_email: "x@y.com"
        })

      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/admin/partners" do
    test "owner sees pending partners with admin JWT (200)", %{conn: conn} do
      Partners.register_partner(@valid_reg)
      {conn, _user, _session} = setup_admin_conn(conn)
      conn = get(conn, "/api/admin/partners")
      assert %{"partners" => partners} = json_response(conn, 200)
      assert length(partners) == 1
    end

    test "returns 401 for regular user JWT (no MFA)", %{conn: conn} do
      conn = user_conn(conn)
      conn = get(conn, "/api/admin/partners")
      assert conn.status == 401
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/admin/partners")
      assert conn.status == 401
    end
  end

  describe "PUT /api/admin/partners/:id/approve" do
    test "admin approves and gets key once (200)", %{conn: conn} do
      {:ok, partner} = Partners.register_partner(@valid_reg)
      {conn, _user, _session} = setup_admin_conn(conn)
      conn = put(conn, "/api/admin/partners/#{partner.id}/approve")
      assert %{"data" => %{"api_key" => key}} = json_response(conn, 200)
      assert String.starts_with?(key, "stacks_pk_")
    end

    test "returns 401 for regular user JWT (no MFA)", %{conn: conn} do
      {:ok, partner} = Partners.register_partner(@valid_reg)
      conn = user_conn(conn)
      conn = put(conn, "/api/admin/partners/#{partner.id}/approve")
      assert conn.status == 401
    end
  end

  describe "PUT /api/admin/partners/:id/reject" do
    test "admin rejects partner (200)", %{conn: conn} do
      {:ok, partner} = Partners.register_partner(@valid_reg)
      {conn, _user, _session} = setup_admin_conn(conn)
      conn = put(conn, "/api/admin/partners/#{partner.id}/reject", %{reason: "Not suitable"})
      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 401 for regular user JWT (no MFA)", %{conn: conn} do
      {:ok, partner} = Partners.register_partner(@valid_reg)
      conn = user_conn(conn)
      conn = put(conn, "/api/admin/partners/#{partner.id}/reject")
      assert conn.status == 401
    end
  end

  describe "PartnerAuthPlug" do
    test "returns :invalid for wrong key" do
      assert {:error, :invalid} =
               Partners.authenticate_partner("stacks_pk_" <> String.duplicate("0", 64))
    end
  end
end
