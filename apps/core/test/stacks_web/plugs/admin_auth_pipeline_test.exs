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

    test "a session survives the request arriving via a DIFFERENT proxy instance",
         %{conn: conn} do
      # Behind Fly, `conn.remote_ip` is the proxy's own peer address and varies
      # between requests. The session must be pinned to the CLIENT
      # (`fly-client-ip`, set authoritatively by Fly's edge), not to whichever
      # proxy carried the password step — pinning to the peer made the very
      # next request answer :ip_mismatch, shown to the operator as
      # "Could not reach the server."
      user = insert(:owner_user)
      boot_id = Core.Application.boot_id()

      # Session minted from a request whose PEER was proxy A but whose client
      # header says 203.0.113.7 — mirroring what the mint site now stores.
      {:ok, session} = SessionContext.create(user, "203.0.113.7", boot_id)
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
        # a different proxy instance this time…
        |> Map.put(:remote_ip, {172, 16, 99, 42})
        # …but the same human on the same connection
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminAuthPipeline.call([])

      refute conn.halted, "the operator did not move; only Fly's routing did"
      assert conn.assigns[:admin_session].id == session.id
    end

    test "a DIFFERENT client behind the trusted header is still refused", %{conn: conn} do
      user = insert(:owner_user)
      boot_id = Core.Application.boot_id()
      {:ok, session} = SessionContext.create(user, "203.0.113.7", boot_id)
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
        |> put_req_header("fly-client-ip", "198.51.100.9")
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
