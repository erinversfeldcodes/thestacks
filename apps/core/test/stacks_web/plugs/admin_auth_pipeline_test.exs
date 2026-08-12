defmodule StacksWeb.Plugs.AdminAuthPipelineTest do
  use CoreWeb.ConnCase, async: false

  import Plug.Conn
  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias StacksWeb.Plugs.AdminAuthPipeline

  @raw_ip "127.0.0.1"

  defp setup_admin_session(user) do
    boot_id = Core.Application.boot_id()
    {:ok, session} = SessionContext.create(user, @raw_ip, boot_id)
    {:ok, session} = SessionContext.mark_mfa_verified(session)

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, %{},
        token_type: "admin",
        session_id: session.id,
        boot_id: boot_id,
        ttl: {30, :minute}
      )

    {token, session}
  end

  describe "AdminAuthPipeline" do
    test "passes with valid admin token and valid session", %{conn: conn} do
      user = insert(:owner_user)
      {token, session} = setup_admin_session(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
      assert conn.assigns[:admin_session].id == session.id
    end

    test "halts with 401 when no Authorization header", %{conn: conn} do
      conn = AdminAuthPipeline.call(conn, [])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 for regular user token (not admin type)", %{conn: conn} do
      user = insert(:user)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 when token has wrong boot_id", %{conn: conn} do
      user = insert(:owner_user)
      boot_id = Core.Application.boot_id()
      {:ok, session} = SessionContext.create(user, @raw_ip, boot_id)

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, %{},
          token_type: "admin",
          session_id: session.id,
          boot_id: Ecto.UUID.generate(),
          ttl: {30, :minute}
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 when session is revoked", %{conn: conn} do
      user = insert(:owner_user)
      {token, session} = setup_admin_session(user)
      {:ok, _} = SessionContext.revoke(session)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 when session is expired", %{conn: conn} do
      user = insert(:owner_user)
      {token, session} = setup_admin_session(user)

      past = DateTime.add(DateTime.utc_now(), -60, :minute)

      session
      |> Ecto.Changeset.change(expires_at: past)
      |> Core.Repo.update!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 when IP does not match session", %{conn: conn} do
      user = insert(:owner_user)

      boot_id = Core.Application.boot_id()
      {:ok, session} = SessionContext.create(user, "10.0.0.1", boot_id)
      {:ok, session} = SessionContext.mark_mfa_verified(session)

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, %{},
          token_type: "admin",
          session_id: session.id,
          boot_id: boot_id,
          ttl: {30, :minute}
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "assigns current_user and admin_session on success", %{conn: conn} do
      user = insert(:owner_user)
      {token, session} = setup_admin_session(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      assert conn.assigns[:current_user] != nil
      assert conn.assigns[:admin_session] != nil
      assert conn.assigns[:admin_session].id == session.id
    end
  end
end
