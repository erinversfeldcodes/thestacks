defmodule StacksWeb.AdminAuthControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.AdminSession
  alias Stacks.MFA

  @raw_ip "127.0.0.1"

  defp setup_mfa_for_user(user) do
    {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
    valid_code = NimbleTOTP.verification_code(secret)
    {:ok, _mfa} = MFA.confirm_enrollment(user, valid_code, secret, codes)
    {secret, codes}
  end

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

  describe "POST /api/admin/auth/login" do
    test "returns 200 with session_id when credentials valid and MFA enrolled", %{conn: conn} do
      user = insert(:owner_user, email: "owner@example.com")
      setup_mfa_for_user(user)

      conn =
        post(conn, "/api/admin/auth/login", %{email: "owner@example.com", password: "password123"})

      assert %{"session_id" => _session_id} = json_response(conn, 200)
    end

    test "returns 401 for wrong password", %{conn: conn} do
      insert(:owner_user, email: "owner2@example.com")

      conn =
        post(conn, "/api/admin/auth/login", %{email: "owner2@example.com", password: "wrongpass"})

      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "returns 403 when user is not owner", %{conn: conn} do
      insert(:user, email: "notowner@example.com")

      conn =
        post(conn, "/api/admin/auth/login", %{
          email: "notowner@example.com",
          password: "password123"
        })

      assert %{"error" => "insufficient_role"} = json_response(conn, 403)
    end

    test "returns 403 when MFA not enrolled", %{conn: conn} do
      insert(:owner_user, email: "ownernofa@example.com")

      conn =
        post(conn, "/api/admin/auth/login", %{
          email: "ownernofa@example.com",
          password: "password123"
        })

      assert %{"error" => "mfa_not_enrolled"} = json_response(conn, 403)
    end

    test "writes admin.login audit row on successful login", %{conn: conn} do
      user = insert(:owner_user, email: "auditlogin@example.com")
      setup_mfa_for_user(user)

      post(conn, "/api/admin/auth/login", %{
        email: "auditlogin@example.com",
        password: "password123"
      })

      {:ok, %{rows: rows, columns: cols}} =
        Repo.query(
          "SELECT action FROM audit.audit_log WHERE action = 'admin.login' ORDER BY occurred_at DESC LIMIT 1"
        )

      assert [[action]] = rows
      assert action == "admin.login"
      _ = cols
    end
  end

  describe "POST /api/admin/auth/verify_mfa" do
    setup do
      user = insert(:owner_user)
      {secret, _codes} = setup_mfa_for_user(user)
      boot_id = Core.Application.boot_id()
      {:ok, session} = SessionContext.create(user, @raw_ip, boot_id)
      {:ok, user: user, session: session, secret: secret}
    end

    test "a valid TOTP code elevates the session and hands back NO credential", %{
      conn: conn,
      user: _user,
      session: session,
      secret: secret
    } do
      totp_code = NimbleTOTP.verification_code(secret)

      conn =
        post(conn, "/api/admin/auth/verify_mfa", %{
          session_id: session.id,
          totp_code: totp_code
        })

      body = json_response(conn, 200)

      assert body == %{"verified" => true}

      # ⛔ THE ASSERTION THAT REPLACED `%{"token" => _token}`. This endpoint used
      # to mint a second Guardian token with a 30-minute TTL, which the SPA held
      # in memory and nothing persisted — so a reload dropped it and re-prompted
      # the operator for a code the server had already accepted. The elevation
      # is recorded on the admin session itself and `AdminAuthPipeline` finds it
      # from the authenticated reader, so a credential here would be a
      # regression rather than a convenience.
      refute Map.has_key?(body, "token"),
             "a credential in this response is the defect: the client cannot keep it across a reload"

      assert Repo.get(AdminSession, session.id, prefix: "op").mfa_verified_at,
             "and the elevation must be recorded where a reload CAN find it"
    end

    test "a recovery code elevates the session and hands back NO credential", %{
      conn: conn,
      user: user,
      session: session
    } do
      {:ok, %{secret: secret2, recovery_codes: codes2}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret2)
      {:ok, _mfa} = MFA.confirm_enrollment(user, valid_code, secret2, codes2)

      recovery_code = List.first(codes2)

      conn =
        post(conn, "/api/admin/auth/verify_mfa", %{
          session_id: session.id,
          recovery_code: recovery_code
        })

      body = json_response(conn, 200)

      assert body == %{"verified" => true}
      refute Map.has_key?(body, "token")

      assert Repo.get(AdminSession, session.id, prefix: "op").mfa_verified_at,
             "a recovery code elevates the session exactly as a TOTP code does"
    end

    test "returns 401 for invalid TOTP code", %{conn: conn, session: session} do
      conn =
        post(conn, "/api/admin/auth/verify_mfa", %{
          session_id: session.id,
          totp_code: "000000"
        })

      assert %{"error" => "invalid_code"} = json_response(conn, 401)
    end

    test "returns 401 for invalid session_id", %{conn: conn} do
      conn =
        post(conn, "/api/admin/auth/verify_mfa", %{
          session_id: Ecto.UUID.generate(),
          totp_code: "123456"
        })

      assert %{"error" => "invalid_session"} = json_response(conn, 401)
    end

    test "returns 401 for revoked session", %{conn: conn, session: session, secret: secret} do
      {:ok, _} = SessionContext.revoke(session)
      totp_code = NimbleTOTP.verification_code(secret)

      conn =
        post(conn, "/api/admin/auth/verify_mfa", %{
          session_id: session.id,
          totp_code: totp_code
        })

      assert %{"error" => "invalid_session"} = json_response(conn, 401)
    end

    test "returns 409 when session is already MFA-verified", %{
      conn: conn,
      session: session,
      secret: secret
    } do
      {:ok, _session} = SessionContext.mark_mfa_verified(session)
      totp_code = NimbleTOTP.verification_code(secret)

      conn =
        post(conn, "/api/admin/auth/verify_mfa", %{
          session_id: session.id,
          totp_code: totp_code
        })

      assert %{"error" => "already_verified"} = json_response(conn, 409)
    end

    test "writes admin.mfa_verified audit row on successful MFA", %{
      conn: conn,
      session: session,
      secret: secret
    } do
      totp_code = NimbleTOTP.verification_code(secret)

      post(conn, "/api/admin/auth/verify_mfa", %{
        session_id: session.id,
        totp_code: totp_code
      })

      {:ok, %{rows: rows}} =
        Repo.query(
          "SELECT action FROM audit.audit_log WHERE action = 'admin.mfa_verified' ORDER BY occurred_at DESC LIMIT 1"
        )

      assert [[action]] = rows
      assert action == "admin.mfa_verified"
    end
  end

  describe "DELETE /api/admin/auth/logout" do
    test "returns 200 and revokes session", %{conn: conn} do
      user = insert(:owner_user)
      {token, session} = setup_admin_session(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/admin/auth/logout")

      assert %{"ok" => true} = json_response(conn, 200)

      # The row itself, not a lookup: logout must retire THIS session, and
      # `current_for_user/2` answering `:not_found` afterwards would also be
      # true if the session had merely stopped being the operator's current one.
      assert Core.Repo.get!(Stacks.AdminSession, session.id, prefix: "op").revoked_at != nil
      assert {:error, :not_found} = SessionContext.current_for_user(user.id, @raw_ip)
    end

    test "returns 401 without admin token", %{conn: conn} do
      conn = delete(conn, "/api/admin/auth/logout")

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/admin/auth/mfa/setup" do
    test "returns provisioning_uri and recovery_codes for owner", %{conn: conn} do
      user = insert(:owner_user)
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/admin/auth/mfa/setup", %{})

      assert %{"provisioning_uri" => _, "recovery_codes" => codes} = json_response(conn, 200)
      assert length(codes) == 10
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn = post(conn, "/api/admin/auth/mfa/setup", %{})

      assert json_response(conn, 401)
    end

    test "returns 403 for non-owner user", %{conn: conn} do
      user = insert(:user)
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/admin/auth/mfa/setup", %{})

      assert json_response(conn, 403)
    end
  end

  describe "POST /api/admin/auth/mfa/confirm" do
    test "returns 200 when valid TOTP code provided", %{conn: conn} do
      user = insert(:owner_user)
      {:ok, token, _} = Guardian.encode_and_sign(user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      totp_code = NimbleTOTP.verification_code(secret)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/admin/auth/mfa/confirm", %{
          totp_code: totp_code,
          secret: Base.encode32(secret, padding: false),
          recovery_codes: codes
        })

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 422 for invalid TOTP code", %{conn: conn} do
      user = insert(:owner_user)
      {:ok, token, _} = Guardian.encode_and_sign(user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/admin/auth/mfa/confirm", %{
          totp_code: "000000",
          secret: Base.encode32(secret, padding: false),
          recovery_codes: codes
        })

      assert %{"error" => "invalid_code"} = json_response(conn, 422)
    end

    test "returns 422 for a malformed secret", %{conn: conn} do
      user = insert(:owner_user)
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/admin/auth/mfa/confirm", %{
          totp_code: "123456",
          secret: "!!!not-valid-base64!!!",
          recovery_codes: []
        })

      assert %{"error" => "invalid_secret"} = json_response(conn, 422)
    end

    test "accepts the secret exactly as `mfa_setup` publishes it — the client's real path" do
      user = insert(:owner_user)
      {:ok, token, _} = Guardian.encode_and_sign(user)
      auth = fn c -> put_req_header(c, "authorization", "Bearer #{token}") end

      %{"provisioning_uri" => uri, "recovery_codes" => codes} =
        CoreWeb.ConnCase.proven_conn()
        |> auth.()
        |> post("/api/admin/auth/mfa/setup")
        |> json_response(200)

      secret_param =
        uri
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()
        |> Map.fetch!("secret")

      {:ok, raw} = Base.decode32(secret_param, padding: false)

      conn =
        CoreWeb.ConnCase.proven_conn()
        |> auth.()
        |> post("/api/admin/auth/mfa/confirm", %{
          totp_code: NimbleTOTP.verification_code(raw),
          secret: secret_param,
          recovery_codes: codes
        })

      assert %{"ok" => true} = json_response(conn, 200),
             "the endpoint rejects the secret its own setup call published"
    end
  end
end
