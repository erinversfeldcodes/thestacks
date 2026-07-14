defmodule StacksWeb.AuthControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.Guardian
  alias StacksWeb.AuthController

  # Reads the most recent audit.audit_log row for a given action via raw SQL so
  # the assertion does not depend on the (proto-generated) Ecto schema shape.
  # user_id is returned as a UUID string; ip_address is returned as stored.
  defp latest_audit_row(action) do
    {:ok, %{rows: [row], columns: cols}} =
      Repo.query(
        """
        SELECT action, resource_type, user_id::text, ip_address
          FROM audit.audit_log
         WHERE action = $1
         ORDER BY occurred_at DESC
         LIMIT 1
        """,
        [action]
      )

    Enum.zip(cols, row) |> Enum.into(%{})
  end

  describe "POST /api/auth/register" do
    test "creates user and returns confirmation_email_sent", %{conn: conn} do
      params = %{email: "new@example.com", password: "password123"}
      conn = post(conn, "/api/auth/register", params)

      assert %{"message" => "confirmation_email_sent"} = json_response(conn, 201)
    end

    test "returns 422 on duplicate email", %{conn: conn} do
      insert(:user, email: "taken@example.com")
      params = %{email: "taken@example.com", password: "password123"}
      conn = post(conn, "/api/auth/register", params)

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 on missing password", %{conn: conn} do
      params = %{email: "nopw@example.com"}
      conn = post(conn, "/api/auth/register", params)

      assert json_response(conn, 422)
    end

    test "includes display_name in registration and stores it", %{conn: conn} do
      params = %{email: "named@example.com", password: "password123", display_name: "Bibliophile"}
      conn = post(conn, "/api/auth/register", params)

      assert %{"message" => "confirmation_email_sent"} = json_response(conn, 201)

      user = Stacks.Accounts.get_user_by_email("named@example.com")
      assert user.display_name == "Bibliophile"
    end

    test "sets email_confirmed to false on new user", %{conn: conn} do
      params = %{email: "unverified@example.com", password: "password123"}
      conn = post(conn, "/api/auth/register", params)

      assert json_response(conn, 201)

      user = Stacks.Accounts.get_user_by_email("unverified@example.com")
      assert user.email_confirmed == false
    end

    test "first registered user gets owner role", %{conn: conn} do
      # Ensure no users exist before this test (ConnCase wraps in a transaction,
      # but this is declared async: false so the table should be empty)
      assert Core.Repo.aggregate(Stacks.Accounts.User, :count, :id) == 0

      params = %{email: "founder@example.com", password: "password123"}
      post(conn, "/api/auth/register", params)

      user = Stacks.Accounts.get_user_by_email("founder@example.com")
      assert user.role == "owner"
    end
  end

  describe "POST /api/auth/login" do
    test "returns JWT on valid credentials", %{conn: conn} do
      insert(:user, email: "login@example.com", password_hash: Argon2.hash_pwd_salt("secret123"))
      params = %{email: "login@example.com", password: "secret123"}
      conn = post(conn, "/api/auth/login", params)

      assert %{"token" => token} = json_response(conn, 200)
      assert is_binary(token)
    end

    test "returns 401 on wrong password", %{conn: conn} do
      insert(:user, email: "wrongpw@example.com", password_hash: Argon2.hash_pwd_salt("correct"))
      params = %{email: "wrongpw@example.com", password: "wrong"}
      conn = post(conn, "/api/auth/login", params)

      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "returns 401 on unknown email", %{conn: conn} do
      params = %{email: "nobody@example.com", password: "password"}
      conn = post(conn, "/api/auth/login", params)

      assert json_response(conn, 401)
    end

    test "returns 403 when email is unconfirmed", %{conn: conn} do
      insert(:user,
        email: "unconfirmed@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: false
      )

      params = %{email: "unconfirmed@example.com", password: "secret123"}
      conn = post(conn, "/api/auth/login", params)

      assert %{"error" => "email_unconfirmed"} = json_response(conn, 403)
    end

    # Punch #1 (Issue #124): missing-field and pool-exhaustion contracts.
    test "returns 422 with a descriptive error when fields are missing", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{})

      assert %{"error" => "email and password are required"} = json_response(conn, 422)
    end

    test "returns 422 when only email is supplied", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "half@example.com"})

      assert %{"error" => "email and password are required"} = json_response(conn, 422)
    end

    test "returns 503 service_busy + Retry-After: 5 when the ArgonPool is exhausted (Issue #166)",
         %{conn: conn} do
      insert(:user,
        email: "busy@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

      # Force the Argon2 pool to report busy quickly instead of the 10s prod
      # default, then saturate every worker so the login verify cannot check
      # out a slot. The login controller must map :argon2_busy -> 503.
      #
      # Both the timeout override and the pool-holder release live in on_exit so
      # a mid-test assertion failure below can't leak the global
      # :argon2_checkout_timeout_ms override or leave the ArgonPool saturated for
      # subsequent tests.
      original_timeout = Application.get_env(:core, :argon2_checkout_timeout_ms)
      Application.put_env(:core, :argon2_checkout_timeout_ms, 25)

      on_exit(fn ->
        if original_timeout do
          Application.put_env(:core, :argon2_checkout_timeout_ms, original_timeout)
        else
          Application.delete_env(:core, :argon2_checkout_timeout_ms)
        end
      end)

      pool_size = Application.get_env(:core, :argon2_pool_size, 2)
      parent = self()

      holders =
        for _ <- 1..pool_size do
          Task.async(fn ->
            NimblePool.checkout!(
              Stacks.Accounts.ArgonPool,
              :checkout,
              fn _from, nil ->
                send(parent, :holding)

                receive do
                  :release -> {nil, nil}
                end
              end,
              5_000
            )
          end)
        end

      # Release every holder from on_exit (best-effort: the pids may already have
      # finished). on_exit runs in a separate process so Task.await/1 isn't
      # available here — the send is enough for each holder to return and free
      # its pool slot.
      on_exit(fn ->
        for t <- holders, do: send(t.pid, :release)
      end)

      for _ <- 1..pool_size, do: assert_receive(:holding, 2_000)

      busy_conn =
        post(conn, "/api/auth/login", %{email: "busy@example.com", password: "secret123"})

      assert %{"error" => "service_busy"} = json_response(busy_conn, 503)
      assert get_resp_header(busy_conn, "retry-after") == ["5"]
    end

    # Punch #6 (Issue #124): a successful login must write a user.login audit
    # entry with the acting user, resource_type "user", and a HASHED ip.
    test "writes a user.login audit entry with a hashed IP on success", %{conn: conn} do
      user =
        insert(:user,
          email: "audit@example.com",
          password_hash: Argon2.hash_pwd_salt("secret123"),
          email_confirmed: true
        )

      # Issue #176: the audit IP is taken from the trusted Fly-Client-IP header
      # (Fly overwrites it at the edge), not the spoofable X-Forwarded-For.
      client_ip = "203.0.113.7"
      expected_hash = :crypto.hash(:sha256, client_ip) |> Base.encode16(case: :lower)

      conn
      |> put_req_header("fly-client-ip", client_ip)
      |> post("/api/auth/login", %{email: "audit@example.com", password: "secret123"})
      |> json_response(200)

      row = latest_audit_row("user.login")

      assert row["action"] == "user.login"
      assert row["resource_type"] == "user"
      assert row["user_id"] == user.id
      # IP must be stored hashed, never in the clear.
      assert row["ip_address"] == expected_hash
      refute row["ip_address"] == client_ip
    end

    # Issue #176: X-Forwarded-For is client-supplied behind Fly and trivially
    # spoofed. It must never be stamped into the audit provenance IP — when no
    # trusted Fly-Client-IP header is present, fall back to conn.remote_ip.
    test "audit IP does not trust X-Forwarded-For", %{conn: conn} do
      user =
        insert(:user,
          email: "audit-xff@example.com",
          password_hash: Argon2.hash_pwd_salt("secret123"),
          email_confirmed: true
        )

      spoofed_ip = "203.0.113.99"
      # The test conn's remote_ip is the loopback default; that is the trusted
      # fallback when no Fly-Client-IP header is set.
      fallback_ip = conn.remote_ip |> :inet.ntoa() |> to_string()
      spoofed_hash = :crypto.hash(:sha256, spoofed_ip) |> Base.encode16(case: :lower)
      fallback_hash = :crypto.hash(:sha256, fallback_ip) |> Base.encode16(case: :lower)

      conn
      |> put_req_header("x-forwarded-for", spoofed_ip)
      |> post("/api/auth/login", %{email: "audit-xff@example.com", password: "secret123"})
      |> json_response(200)

      row = latest_audit_row("user.login")

      assert row["user_id"] == user.id
      # The spoofed X-Forwarded-For must NOT be the recorded provenance IP.
      refute row["ip_address"] == spoofed_hash
      # The trusted fallback (remote_ip) is what gets hashed and stored.
      assert row["ip_address"] == fallback_hash
    end
  end

  describe "POST /api/auth/login per-account lockout (Issue #161)" do
    setup do
      # Tight threshold for fast tests.
      threshold = Application.get_env(:core, :login_lockout_threshold)
      window = Application.get_env(:core, :login_lockout_window_seconds)
      duration = Application.get_env(:core, :login_lockout_duration_seconds)

      Application.put_env(:core, :login_lockout_threshold, 3)
      Application.put_env(:core, :login_lockout_window_seconds, 60)
      Application.put_env(:core, :login_lockout_duration_seconds, 120)

      on_exit(fn ->
        Application.put_env(:core, :login_lockout_threshold, threshold)
        Application.put_env(:core, :login_lockout_window_seconds, window)
        Application.put_env(:core, :login_lockout_duration_seconds, duration)
      end)

      :ok
    end

    test "returns 423 with account_locked + retry_after_seconds after threshold failures",
         %{conn: conn} do
      insert(:user,
        email: "lockme@example.com",
        password_hash: Argon2.hash_pwd_salt("right-pass"),
        email_confirmed: true
      )

      # Burn through the threshold with wrong passwords.
      for _ <- 1..3 do
        post(conn, "/api/auth/login", %{email: "lockme@example.com", password: "wrong"})
      end

      # The next attempt — even with the correct password — must be 423.
      locked_conn =
        post(conn, "/api/auth/login", %{email: "lockme@example.com", password: "right-pass"})

      body = json_response(locked_conn, 423)
      assert body["error"] == "account_locked"
      assert is_integer(body["retry_after_seconds"])
      assert body["retry_after_seconds"] > 0
    end

    test "unknown email returns generic invalid_credentials (no enumeration)",
         %{conn: conn} do
      response_conn =
        post(conn, "/api/auth/login", %{email: "no-such-user@example.com", password: "anything"})

      assert json_response(response_conn, 401) == %{"error" => "invalid_credentials"}
    end
  end

  describe "GET /api/auth/me" do
    test "returns current user when authenticated", %{conn: conn} do
      user = insert(:user, email: "me@example.com")
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert %{"user" => returned_user} = json_response(conn, 200)
      assert returned_user["email"] == "me@example.com"
    end

    test "returns 401 without token", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/auth/logout" do
    test "returns 204 on logout", %{conn: conn} do
      user = insert(:user)
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/auth/logout")

      assert response(conn, 204)
    end

    test "returns 401 without token", %{conn: conn} do
      conn = delete(conn, "/api/auth/logout")
      assert json_response(conn, 401)
    end
  end

  describe "JWT lifecycle on GET /api/auth/me (Issue #124)" do
    # Punch #2: an expired JWT (driven through the real Guardian TTL/exp, not a
    # hand-built AuthErrorHandler unit) must be rejected with 401.
    test "an expired JWT is rejected with 401", %{conn: conn} do
      user = insert(:user, email: "expired@example.com", email_confirmed: true)
      {:ok, expired_token, _claims} = Guardian.encode_and_sign(user, %{}, ttl: {-1, :hour})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{expired_token}")
        |> get("/api/auth/me")

      assert json_response(conn, 401)
    end

    # Punch #4: after logout the SAME JWT must be rejected (401). This can only
    # pass once server-side revocation (A2) is in place — before A2, revoke is a
    # no-op and the token stays valid (200).
    test "the same JWT is rejected with 401 after logout", %{conn: conn} do
      user = insert(:user, email: "revoke@example.com", email_confirmed: true)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      # Sanity: the token works before logout.
      pre_logout =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert json_response(pre_logout, 200)

      # Log out — this must revoke the token server-side.
      logout_conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/auth/logout")

      assert response(logout_conn, 204)

      # The same token must now be rejected.
      post_logout =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert json_response(post_logout, 401)
    end
  end

  describe "POST /api/auth/refresh" do
    # Issue #173, Phase 1: proactive silent-renewal. Exchange a valid,
    # non-revoked, non-expired JWT for a fresh one behind the :authenticated
    # pipeline. The pipeline rejects expired/revoked/absent tokens with 401
    # before the controller runs; a valid token is rotated (old token revoked,
    # new token minted) and returned in login's %{token, user} shape.

    test "returns 200 with a fresh, different, verifiable token and a user object",
         %{conn: conn} do
      user = insert(:user, email: "refresh-happy@example.com", email_confirmed: true)
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user)

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"token" => new_token, "user" => returned_user} = json_response(refresh_conn, 200)

      # The new token must be a non-empty binary and DIFFERENT from the old one.
      assert is_binary(new_token)
      assert new_token != ""
      assert new_token != old_token

      # The user payload mirrors login's ProtoJSON.user shape.
      assert returned_user["email"] == "refresh-happy@example.com"

      # The freshly minted token must itself verify.
      assert {:ok, _new_claims} = Guardian.decode_and_verify(new_token)
    end

    test "rotates the old token so it is no longer usable after a refresh",
         %{conn: conn} do
      user = insert(:user, email: "refresh-rotate@example.com", email_confirmed: true)
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user)

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"token" => new_token} = json_response(refresh_conn, 200)
      assert new_token != old_token

      # Rotation proof: the OLD token must no longer authenticate — a subsequent
      # authed request with it is rejected 401 (its guardian_tokens row is gone).
      stale_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> get("/api/auth/me")

      assert json_response(stale_conn, 401)
    end

    test "returns 401 when the token has been revoked (logged out)", %{conn: conn} do
      user = insert(:user, email: "refresh-revoked@example.com", email_confirmed: true)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      # Revoke server-side (deletes the guardian_tokens row), mirroring logout.
      {:ok, _claims} = Guardian.revoke(token)

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/auth/refresh")

      assert json_response(refresh_conn, 401)
    end

    test "returns 401 when the token has already expired", %{conn: conn} do
      user = insert(:user, email: "refresh-expired@example.com", email_confirmed: true)
      {:ok, expired_token, _claims} = Guardian.encode_and_sign(user, %{}, ttl: {-1, :hour})

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{expired_token}")
        |> post("/api/auth/refresh")

      assert json_response(refresh_conn, 401)
    end

    test "returns 401 when no Authorization header is present", %{conn: conn} do
      refresh_conn = post(conn, "/api/auth/refresh")

      assert json_response(refresh_conn, 401)
    end

    # Issue #181: when Guardian.revoke fails during refresh the action still
    # mints a fresh token (degraded rotation — the old token stays valid until
    # its TTL expires) but the degraded case must be counted/alertable via
    # telemetry, in addition to the existing Logger.warning.
    #
    # Forcing a real revoke failure for a token that passed the :authenticated
    # pipeline is not possible through the router (a valid token revokes
    # cleanly). We instead call the action directly with a current_token that
    # cannot be peeked: Guardian.revoke("not-a-real-token") returns
    # {:error, :not_found}, driving the genuine revoke-failure branch with no
    # production seam. The mint uses the resource, so the response is a normal
    # 200 and behaviour is unchanged.
    test "emits [:stacks, :auth, :refresh, :revoke_failed] telemetry when the old token cannot be revoked",
         %{conn: conn} do
      user = insert(:user, email: "refresh-revoke-fail@example.com", email_confirmed: true)

      test_pid = self()
      handler_id = "test-refresh-revoke-failed-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:stacks, :auth, :refresh, :revoke_failed],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      refresh_conn =
        conn
        |> Guardian.Plug.put_current_resource(user)
        |> Guardian.Plug.put_current_token("not-a-real-token")
        |> AuthController.refresh(%{})

      # Behaviour is unchanged: a fresh token is still minted and returned 200.
      assert %{"token" => new_token} = json_response(refresh_conn, 200)
      assert is_binary(new_token) and new_token != ""

      # The degraded case is now counted/alertable.
      assert_receive {:telemetry, [:stacks, :auth, :refresh, :revoke_failed], %{count: 1}, %{}}
    end

    # ---------------------------------------------------------------------
    # Issue #179, Phase 1: absolute session-lifetime cap (7 days).
    #
    # A session carries a "sst" (session-start) anchor stamped in unix seconds
    # at LOGIN. Refresh may rotate the token indefinitely up to 7 days from that
    # ORIGINAL issue; the anchor is carried forward on every rotation (it does
    # NOT reset), so once 7 days elapse from the first login the session can no
    # longer be renewed and refresh returns 401.
    # ---------------------------------------------------------------------

    test "an in-cap refresh preserves the original sst anchor (survives rotation)",
         %{conn: conn} do
      user = insert(:user, email: "refresh-sst-preserved@example.com", email_confirmed: true)
      now = System.system_time(:second)
      original_sst = now - 3600
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user, %{"sst" => original_sst})

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"token" => new_token} = json_response(refresh_conn, 200)

      # Non-vacuity: a normal in-cap refresh still rotates to a fresh token.
      assert new_token != old_token

      # Survive-rotation: the NEW token's sst equals the ORIGINAL, not reset to now.
      assert {:ok, new_claims} = Guardian.decode_and_verify(new_token)
      assert new_claims["sst"] == original_sst
    end

    test "refresh past the absolute cap returns 401 session_expired and revokes the old token",
         %{conn: conn} do
      user = insert(:user, email: "refresh-cap-exceeded@example.com", email_confirmed: true)
      now = System.system_time(:second)
      # 8 days ago — beyond the 7-day cap.
      old_sst = now - 8 * 24 * 3600
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user, %{"sst" => old_sst})

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"error" => "session_expired"} = json_response(refresh_conn, 401)

      # The presented token is revoked even though no new token was minted:
      # a follow-up authed request with it is rejected 401.
      stale_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> get("/api/auth/me")

      assert json_response(stale_conn, 401)
    end

    test "minting a token stamps a session-start anchor (sst) approximately now",
         %{conn: _conn} do
      user = insert(:user, email: "sst-stamp@example.com", email_confirmed: true)
      now = System.system_time(:second)

      # login/2 mints via Guardian.encode_and_sign(user) with no explicit claims.
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      assert {:ok, claims} = Guardian.decode_and_verify(token)
      assert is_integer(claims["sst"])
      assert_in_delta claims["sst"], now, 5
    end

    test "a legacy session with no sst claim is stamped forward (bounded from now), not locked out",
         %{conn: conn} do
      user = insert(:user, email: "refresh-legacy@example.com", email_confirmed: true)
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user)
      now = System.system_time(:second)

      # Simulate a token minted BEFORE the absolute-cap change: current_claims
      # carries no "sst". Drive the action directly with a real, revocable token
      # so the missing-sst policy (stamp forward to now) is exercised without a
      # production seam.
      refresh_conn =
        conn
        |> Guardian.Plug.put_current_resource(user)
        |> Guardian.Plug.put_current_token(old_token)
        |> Guardian.Plug.put_current_claims(%{"sub" => to_string(user.id)})
        |> AuthController.refresh(%{})

      # Not a 500, not a lock-out: a fresh token is minted and returned.
      assert %{"token" => new_token} = json_response(refresh_conn, 200)

      # The legacy session is now bounded: sst is stamped forward to ~now.
      assert {:ok, new_claims} = Guardian.decode_and_verify(new_token)
      assert is_integer(new_claims["sst"])
      assert_in_delta new_claims["sst"], now, 5
    end
  end

  describe "refresh-token families (Issue #179, Phase 2a)" do
    # A session opens exactly one family at login. The family's current_jti
    # tracks the single live access token; refresh advances that jti in place
    # (same row, same family_id) rather than opening a new family, so the whole
    # rotation chain remains one revocable unit (Phase 2b).

    test "login opens exactly one family whose current_jti is the minted token's jti",
         %{conn: conn} do
      user =
        insert(:user,
          email: "family-login@example.com",
          password_hash: Argon2.hash_pwd_salt("secret123"),
          email_confirmed: true
        )

      login_conn =
        post(conn, "/api/auth/login", %{email: "family-login@example.com", password: "secret123"})

      assert %{"token" => token} = json_response(login_conn, 200)
      assert {:ok, claims} = Guardian.decode_and_verify(token)

      # Exactly one family row (sandboxed transaction → only this test's rows).
      assert Repo.aggregate(AuthTokenFamily, :count, :family_id) == 1

      family = Repo.get(AuthTokenFamily, claims["family_id"])
      assert family
      assert family.current_jti == claims["jti"]
      assert family.user_id == user.id
      assert is_nil(family.revoked_at)
    end

    test "the minted login token carries a family_id claim", %{conn: conn} do
      insert(:user,
        email: "family-claim@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

      login_conn =
        post(conn, "/api/auth/login", %{email: "family-claim@example.com", password: "secret123"})

      assert %{"token" => token} = json_response(login_conn, 200)
      assert {:ok, claims} = Guardian.decode_and_verify(token)
      assert is_binary(claims["family_id"])
    end

    test "refresh advances the SAME family's current_jti and preserves the family_id",
         %{conn: conn} do
      insert(:user,
        email: "family-refresh@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

      login_conn =
        post(conn, "/api/auth/login", %{
          email: "family-refresh@example.com",
          password: "secret123"
        })

      assert %{"token" => old_token} = json_response(login_conn, 200)
      assert {:ok, old_claims} = Guardian.decode_and_verify(old_token)

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"token" => new_token} = json_response(refresh_conn, 200)
      assert {:ok, new_claims} = Guardian.decode_and_verify(new_token)

      # Same family carried across rotation; the token itself rotated.
      assert new_claims["family_id"] == old_claims["family_id"]
      assert new_claims["jti"] != old_claims["jti"]

      # Still exactly one family — refresh updated, did not open a new one.
      assert Repo.aggregate(AuthTokenFamily, :count, :family_id) == 1

      family = Repo.get(AuthTokenFamily, old_claims["family_id"])
      assert family.current_jti == new_claims["jti"]
      refute family.current_jti == old_claims["jti"]
    end

    test "a legacy token with no family_id is adopted into a family on refresh (no 500)",
         %{conn: conn} do
      user =
        insert(:user, email: "family-legacy@example.com", email_confirmed: true)

      # Token minted the old way: no family_id claim. Drive the action directly
      # with claims that carry neither sst nor family_id (a pre-Phase-2a session)
      # so the lazy-adopt path is exercised without a production seam.
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user)

      refresh_conn =
        conn
        |> Guardian.Plug.put_current_resource(user)
        |> Guardian.Plug.put_current_token(old_token)
        |> Guardian.Plug.put_current_claims(%{"sub" => to_string(user.id)})
        |> AuthController.refresh(%{})

      # Not a 500, not a lock-out: a fresh token is minted and returned.
      assert %{"token" => new_token} = json_response(refresh_conn, 200)
      assert {:ok, new_claims} = Guardian.decode_and_verify(new_token)

      # The legacy session is now tracked: a family row was lazily created.
      assert is_binary(new_claims["family_id"])
      family = Repo.get(AuthTokenFamily, new_claims["family_id"])
      assert family
      assert family.current_jti == new_claims["jti"]
      assert family.user_id == user.id
    end
  end

  describe "reuse detection & family revocation (Issue #179, Phase 2b)" do
    # A refresh-token family is one rotation chain. `current_jti` names the
    # single live token; every OTHER jti in the family is superseded. Presenting
    # a superseded token on any authed request is REUSE (an already-rotated
    # token replayed, benignly by a stale tab or maliciously by a thief). The
    # verify_claims gate — which runs on EVERY request, before guardian_db's
    # on_verify row-presence check — detects the non-current jti and revokes the
    # WHOLE family, burning the live token too. #180 adds a 20s grace window for
    # the IMMEDIATELY-PREVIOUS token only, so a genuine reuse is now a token
    # OLDER than the immediate predecessor (2+ rotations back) or the previous
    # token past grace — both still burn.
    defp login_token!(conn, email) do
      insert(:user,
        email: email,
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

      login_conn = post(conn, "/api/auth/login", %{email: email, password: "secret123"})
      %{"token" => token} = json_response(login_conn, 200)
      {:ok, claims} = Guardian.decode_and_verify(token)
      {token, claims}
    end

    test "replaying an older (2-rotations-back) token 401s AND revokes the whole family",
         %{conn: conn} do
      {token_a, claims_a} = login_token!(conn, "reuse-detect@example.com")
      family_id = claims_a["family_id"]

      # Rotate twice: A → B → C. Token B is now the immediate predecessor (inside
      # the #180 grace window); token A is TWO rotations back — past the grace
      # window's single-predecessor scope, so replaying it is genuine reuse.
      refresh_b =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_b, 200)

      refresh_c =
        conn |> put_req_header("authorization", "Bearer #{token_b}") |> post("/api/auth/refresh")

      assert %{"token" => token_c} = json_response(refresh_c, 200)

      # Replay the OLD token A (2-back) on an authed endpoint → 401 (reuse). Grace
      # applies only to the immediate predecessor (B), never to A.
      replay_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> get("/api/auth/me")

      assert json_response(replay_conn, 401)

      # The whole family is now revoked (revoked_at stamped)...
      family = Repo.get(AuthTokenFamily, family_id)
      assert family.revoked_at

      # ...so the CURRENT token C is ALSO rejected — a detected replay burns the
      # entire session, not just the replayed token.
      burned_conn =
        conn |> put_req_header("authorization", "Bearer #{token_c}") |> get("/api/auth/me")

      assert json_response(burned_conn, 401)
    end

    test "the current token keeps working after a refresh (no false revoke)",
         %{conn: conn} do
      {token_a, _claims_a} = login_token!(conn, "reuse-happy@example.com")

      refresh_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_conn, 200)
      assert {:ok, claims_b} = Guardian.decode_and_verify(token_b)

      # Non-vacuity: the legit CURRENT token verifies repeatedly and does NOT
      # trip the reuse gate (guards against over-revoking on every request).
      ok1 = conn |> put_req_header("authorization", "Bearer #{token_b}") |> get("/api/auth/me")
      assert json_response(ok1, 200)
      ok2 = conn |> put_req_header("authorization", "Bearer #{token_b}") |> get("/api/auth/me")
      assert json_response(ok2, 200)

      family = Repo.get(AuthTokenFamily, claims_b["family_id"])
      assert is_nil(family.revoked_at)
    end

    test "logout revokes the family so an attacker's rotated chain dies too",
         %{conn: conn} do
      {token_a, _claims_a} = login_token!(conn, "logout-family@example.com")

      # Refresh so the family has a live current token (token B).
      refresh_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_conn, 200)
      assert {:ok, claims_b} = Guardian.decode_and_verify(token_b)

      # Log out with the current token.
      logout_conn =
        conn |> put_req_header("authorization", "Bearer #{token_b}") |> delete("/api/auth/logout")

      assert response(logout_conn, 204)

      # The current token is dead...
      after_conn =
        conn |> put_req_header("authorization", "Bearer #{token_b}") |> get("/api/auth/me")

      assert json_response(after_conn, 401)

      # ...and the family is marked revoked, so any rotated token sharing this
      # family_id (e.g. a thief's already-rotated chain) is rejected on next use.
      family = Repo.get(AuthTokenFamily, claims_b["family_id"])
      assert family.revoked_at
    end
  end

  describe "rotation grace window (Issue #180, Phase 1)" do
    # Rotation records the predecessor jti + rotated_at so the reuse gate can
    # honour the JUST-rotated old token for a short grace window (20s) instead
    # of burning the family on a benign in-flight / multi-tab race.
    defp login_token_g!(conn, email) do
      insert(:user,
        email: email,
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

      login_conn = post(conn, "/api/auth/login", %{email: email, password: "secret123"})
      %{"token" => token} = json_response(login_conn, 200)
      {:ok, claims} = Guardian.decode_and_verify(token)
      {token, claims}
    end

    test "refresh records the predecessor jti and rotated_at on the family",
         %{conn: conn} do
      {token_a, claims_a} = login_token_g!(conn, "grace-predecessor@example.com")
      family_id = claims_a["family_id"]

      before = DateTime.utc_now()

      refresh_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_conn, 200)
      {:ok, claims_b} = Guardian.decode_and_verify(token_b)

      family = Repo.get(AuthTokenFamily, family_id)
      # The OLD token's jti is preserved as the predecessor; current advanced.
      assert family.previous_jti == claims_a["jti"]
      assert family.current_jti == claims_b["jti"]
      # rotated_at was stamped ~now (at or after the pre-refresh timestamp).
      assert family.rotated_at
      assert DateTime.compare(family.rotated_at, before) in [:gt, :eq]
    end

    test "the just-rotated old token is honoured by the family gate within grace (no false burn)",
         %{conn: conn} do
      {token_a, claims_a} = login_token_g!(conn, "grace-inflight@example.com")

      # Rotate → token B. token A's jti is now the immediate predecessor,
      # rotated ~now. (guardian_db deletes token A's row on rotation, so we
      # exercise the family gate directly with the captured predecessor jti.)
      refresh_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_conn, 200)
      {:ok, claims_b} = Guardian.decode_and_verify(token_b)

      # An in-flight request carrying the just-rotated old token: honoured within
      # grace (would 401 + burn the whole family under bare #179).
      assert :ok =
               Accounts.check_token_family(
                 claims_b["family_id"],
                 claims_a["jti"],
                 claims_a["sub"]
               )

      # And the family is NOT revoked — the current token keeps working.
      family = Repo.get(AuthTokenFamily, claims_b["family_id"])
      assert is_nil(family.revoked_at)
    end
  end

  describe "POST /api/auth/forgot-password" do
    test "returns 200 for a registered email", %{conn: conn} do
      insert(:user, email: "forgotme@example.com")
      conn = post(conn, "/api/auth/forgot-password", %{email: "forgotme@example.com"})

      assert %{"message" => _} = json_response(conn, 200)
    end

    test "returns 200 for an unregistered email (no enumeration)", %{conn: conn} do
      conn = post(conn, "/api/auth/forgot-password", %{email: "nobody@example.com"})

      assert %{"message" => _} = json_response(conn, 200)
    end

    test "returns 422 when email param is missing", %{conn: conn} do
      conn = post(conn, "/api/auth/forgot-password", %{})

      assert json_response(conn, 422)
    end
  end

  describe "POST /api/auth/reset-password" do
    test "returns 200 with a valid reset token", %{conn: conn} do
      user = insert(:user)
      Stacks.Email.send_password_reset(user.email)
      updated_user = Core.Repo.reload!(user)
      token = updated_user.password_reset_token

      conn =
        post(conn, "/api/auth/reset-password", %{token: token, password: "newpassword123"})

      assert %{"message" => _} = json_response(conn, 200)
    end

    test "returns 400 with an invalid token", %{conn: conn} do
      conn =
        post(conn, "/api/auth/reset-password", %{token: "bad-token", password: "newpassword123"})

      assert json_response(conn, 400)
    end

    test "returns 422 when params are missing", %{conn: conn} do
      conn = post(conn, "/api/auth/reset-password", %{})

      assert json_response(conn, 422)
    end
  end

  describe "rate limiting on auth endpoints" do
    # Rate limiting is disabled in test.exs by default to keep tests fast.
    # This describe block re-enables it and uses a dedicated IP range
    # (10.99.x.x) to avoid cross-test contamination. ETS is cleared after
    # each test so counts don't bleed across tests in this block.
    #
    # The :auth bucket's production default is 60/60s — sized for
    # NAT-shared IPs hitting login traffic. Pin a tight 5/60s value
    # here so the boundary tests below can fire with a small loop
    # rather than 60+ HTTP requests. See rate_limiter.ex moduledoc
    # for the prod sizing rationale and rate_limiter_test.exs for the
    # same per-test override pattern.
    setup do
      original = Application.get_env(:core, :rate_limiting_enabled)
      Application.put_env(:core, :rate_limiting_enabled, true)

      original_auth = Application.get_env(:core, :rate_limit_auth)
      Application.put_env(:core, :rate_limit_auth, 5)

      on_exit(fn ->
        Application.put_env(:core, :rate_limiting_enabled, original)

        if original_auth do
          Application.put_env(:core, :rate_limit_auth, original_auth)
        else
          Application.delete_env(:core, :rate_limit_auth)
        end

        if :ets.whereis(:rate_limiter) != :undefined do
          :ets.delete_all_objects(:rate_limiter)
        end
      end)

      :ok
    end

    test "returns 429 after exceeding rate limit on register", %{conn: conn} do
      # Use a dedicated IP so these requests don't interfere with other tests.
      # Issue #176: the limiter keys on the trusted Fly-Client-IP header, not
      # the spoofable X-Forwarded-For.
      conn = put_req_header(conn, "fly-client-ip", "10.99.1.1")

      for n <- 1..5 do
        post(conn, "/api/auth/register", %{
          email: "flood#{n}@example.com",
          password: "password123"
        })
      end

      rate_limited_conn =
        post(conn, "/api/auth/register", %{
          email: "flood6@example.com",
          password: "password123"
        })

      assert response(rate_limited_conn, 429)
    end

    test "returns 429 after exceeding rate limit on login", %{conn: conn} do
      # Use a dedicated IP so these requests don't interfere with other tests.
      # Issue #176: the limiter keys on the trusted Fly-Client-IP header, not
      # the spoofable X-Forwarded-For.
      conn = put_req_header(conn, "fly-client-ip", "10.99.1.2")

      insert(:user,
        email: "ratelimited@example.com",
        password_hash: Argon2.hash_pwd_salt("correct123")
      )

      for _ <- 1..5 do
        post(conn, "/api/auth/login", %{
          email: "ratelimited@example.com",
          password: "wrong-password"
        })
      end

      rate_limited_conn =
        post(conn, "/api/auth/login", %{
          email: "ratelimited@example.com",
          password: "wrong-password"
        })

      assert response(rate_limited_conn, 429)
    end

    # Issue #176 integration proof: buckets must be keyed on the trusted
    # Fly-Client-IP through the real :api → RateLimiter pipeline, NOT on the
    # shared remote_ip. Two clients differ ONLY by Fly-Client-IP (same conn /
    # remote_ip); exhausting client A must not spill onto client B. Against the
    # old XFF impl this is RED — it ignores fly-client-ip, so A and B collapse
    # into one remote_ip bucket and B would be blocked.
    test "per-Fly-Client-IP isolation: exhausting one client does not block another",
         %{conn: conn} do
      client_a = put_req_header(conn, "fly-client-ip", "10.99.2.1")
      client_b = put_req_header(conn, "fly-client-ip", "10.99.2.2")

      # Exhaust client A's :auth bucket (pinned limit 5).
      for n <- 1..5 do
        post(client_a, "/api/auth/register", %{
          email: "iso-a#{n}@example.com",
          password: "password123"
        })
      end

      overflow_a =
        post(client_a, "/api/auth/register", %{
          email: "iso-a6@example.com",
          password: "password123"
        })

      assert response(overflow_a, 429)

      # Client B shares the remote_ip but has a distinct Fly-Client-IP — it must
      # still be allowed (registration succeeds with 201, not a 429).
      allowed_b =
        post(client_b, "/api/auth/register", %{
          email: "iso-b1@example.com",
          password: "password123"
        })

      assert json_response(allowed_b, 201)
    end
  end

  describe "integration: register → confirm → login → access protected route → logout" do
    test "full auth flow works end to end", %{conn: conn} do
      # Register — returns confirmation message, no JWT
      reg_conn =
        post(conn, "/api/auth/register", %{email: "flow@example.com", password: "password123"})

      assert %{"message" => "confirmation_email_sent"} = json_response(reg_conn, 201)

      # Login fails before confirmation
      pre_confirm_conn =
        post(conn, "/api/auth/login", %{email: "flow@example.com", password: "password123"})

      assert %{"error" => "email_unconfirmed"} = json_response(pre_confirm_conn, 403)

      # Confirm the user's email directly (in production this happens via
      # the confirmation link, but Oban jobs don't run in :manual test mode)
      user = Stacks.Accounts.get_user_by_email("flow@example.com")

      {:ok, _} =
        user
        |> Accounts.email_confirmation_changeset(%{
          email_confirmed: true,
          email_confirmation_token: nil
        })
        |> Core.Repo.update()

      # Login succeeds after confirmation
      login_conn =
        post(conn, "/api/auth/login", %{email: "flow@example.com", password: "password123"})

      assert %{"token" => login_token} = json_response(login_conn, 200)

      # Access protected route
      me_conn =
        conn
        |> put_req_header("authorization", "Bearer #{login_token}")
        |> get("/api/auth/me")

      assert %{"user" => returned_user} = json_response(me_conn, 200)
      assert returned_user["email"] == "flow@example.com"

      # Logout
      logout_conn =
        conn
        |> put_req_header("authorization", "Bearer #{login_token}")
        |> delete("/api/auth/logout")

      assert response(logout_conn, 204)
    end
  end

  # ── Auth §12 operational-metric emission (Issue #206) ──────────────────────
  #
  # Proves the auth counters actually FIRE from the real controller code paths
  # (not just that PromEx can export them — that is the reporter-tag-set proof
  # in prom_ex_custom_metrics_test.exs). Each test attaches a real telemetry
  # handler, drives the endpoint, and asserts the exact event + bounded tag.
  # Removing any emitter makes the corresponding assert_receive time out.
  describe "auth §12 telemetry emission" do
    defp attach_auth_events(events) do
      test_pid = self()
      handler_id = "test-auth-206-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "register success emits [:stacks, :auth, :registration] result: :ok", %{conn: conn} do
      attach_auth_events([[:stacks, :auth, :registration]])

      post(conn, "/api/auth/register", %{email: "reg-ok@example.com", password: "password123"})

      assert_receive {:telemetry_event, [:stacks, :auth, :registration], %{count: 1},
                      %{result: :ok}}
    end

    test "register failure emits [:stacks, :auth, :registration] result: :error", %{conn: conn} do
      insert(:user, email: "dupe@example.com")
      attach_auth_events([[:stacks, :auth, :registration]])

      post(conn, "/api/auth/register", %{email: "dupe@example.com", password: "password123"})

      assert_receive {:telemetry_event, [:stacks, :auth, :registration], %{count: 1},
                      %{result: :error}}
    end

    test "login success emits [:stacks, :auth, :jwt_issued] context: :login", %{conn: conn} do
      insert(:user,
        email: "jwt@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

      attach_auth_events([[:stacks, :auth, :jwt_issued]])

      post(conn, "/api/auth/login", %{email: "jwt@example.com", password: "secret123"})
      |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :auth, :jwt_issued], %{count: 1},
                      %{context: :login}}
    end

    test "refresh emits [:stacks, :auth, :jwt_issued] context: :refresh", %{conn: conn} do
      user = insert(:user, email: "refresh@example.com", email_confirmed: true)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)
      attach_auth_events([[:stacks, :auth, :jwt_issued]])

      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/auth/refresh", %{})
      |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :auth, :jwt_issued], %{count: 1},
                      %{context: :refresh}}
    end

    test "401 invalid credentials emits login_failure type: :invalid_credentials", %{conn: conn} do
      insert(:user,
        email: "badpw@example.com",
        password_hash: Argon2.hash_pwd_salt("correct"),
        email_confirmed: true
      )

      attach_auth_events([[:stacks, :auth, :login_failure]])

      post(conn, "/api/auth/login", %{email: "badpw@example.com", password: "wrong"})

      assert_receive {:telemetry_event, [:stacks, :auth, :login_failure], %{count: 1},
                      %{type: :invalid_credentials}}
    end

    test "403 unconfirmed email emits login_failure type: :email_unconfirmed", %{conn: conn} do
      insert(:user,
        email: "unconf@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: false
      )

      attach_auth_events([[:stacks, :auth, :login_failure]])

      post(conn, "/api/auth/login", %{email: "unconf@example.com", password: "secret123"})

      assert_receive {:telemetry_event, [:stacks, :auth, :login_failure], %{count: 1},
                      %{type: :email_unconfirmed}}
    end

    test "422 missing params emits login_failure type: :missing_params", %{conn: conn} do
      attach_auth_events([[:stacks, :auth, :login_failure]])

      post(conn, "/api/auth/login", %{})

      assert_receive {:telemetry_event, [:stacks, :auth, :login_failure], %{count: 1},
                      %{type: :missing_params}}
    end
  end
end
