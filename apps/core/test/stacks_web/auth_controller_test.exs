defmodule StacksWeb.AuthControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian

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
end
