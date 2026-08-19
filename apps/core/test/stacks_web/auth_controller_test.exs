defmodule StacksWeb.AuthControllerTest do
  use CoreWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.Guardian
  alias Stacks.Workers.EmailDeliveryJob
  alias StacksWeb.AuthController

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

  defp resend_response(email) do
    mirror_response("/api/auth/resend-confirmation", email)
  end

  defp forgot_password_response(email) do
    mirror_response("/api/auth/forgot-password", email)
  end

  defp mirror_response(path, email) do
    conn = post(build_conn(), path, %{email: email})

    %{
      status: conn.status,
      body: conn.resp_body,
      headers:
        conn.resp_headers
        |> Enum.reject(fn {name, _value} -> name == "x-request-id" end)
        |> Enum.sort()
    }
  end

  # Ten EmailDeliveryJob rows inside the hour puts this user over the email
  # limiter's per-user ceiling, so their next transactional mail is suppressed.
  defp saturate_email_limit(user_id) do
    for _ <- 1..10 do
      EmailDeliveryJob.new(%{
        "template" => "registration_confirmation",
        "user_id" => user_id,
        "params" => %{"token" => "saturating-the-limiter"}
      })
      |> Oban.insert!()
    end
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

    test "returns 422 with a descriptive error when fields are missing", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{})

      assert %{"error" => "email and password are required"} = json_response(conn, 422)
    end

    test "returns 422 when only email is supplied", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "half@example.com"})

      assert %{"error" => "email and password are required"} = json_response(conn, 422)
    end

    test "returns 503 service_busy + Retry-After: 5 when the ArgonPool is exhausted",
         %{conn: conn} do
      insert(:user,
        email: "busy@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

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

      on_exit(fn ->
        for t <- holders, do: send(t.pid, :release)
      end)

      for _ <- 1..pool_size, do: assert_receive(:holding, 2_000)

      busy_conn =
        post(conn, "/api/auth/login", %{email: "busy@example.com", password: "secret123"})

      assert %{"error" => "service_busy"} = json_response(busy_conn, 503)
      assert get_resp_header(busy_conn, "retry-after") == ["5"]
    end

    test "writes a user.login audit entry with a hashed IP on success", %{conn: conn} do
      user =
        insert(:user,
          email: "audit@example.com",
          password_hash: Argon2.hash_pwd_salt("secret123"),
          email_confirmed: true
        )

      client_ip = "203.0.113.7"
      expected_hash = Stacks.IPDigest.hash(client_ip)

      conn
      |> put_req_header("fly-client-ip", client_ip)
      |> post("/api/auth/login", %{email: "audit@example.com", password: "secret123"})
      |> json_response(200)

      row = latest_audit_row("user.login")

      assert row["action"] == "user.login"
      assert row["resource_type"] == "user"
      assert row["user_id"] == user.id
      assert row["ip_address"] == expected_hash
      refute row["ip_address"] == client_ip
    end

    test "audit IP does not trust X-Forwarded-For", %{conn: conn} do
      user =
        insert(:user,
          email: "audit-xff@example.com",
          password_hash: Argon2.hash_pwd_salt("secret123"),
          email_confirmed: true
        )

      spoofed_ip = "203.0.113.99"
      fallback_ip = conn.remote_ip |> :inet.ntoa() |> to_string()
      spoofed_hash = Stacks.IPDigest.hash(spoofed_ip)
      fallback_hash = Stacks.IPDigest.hash(fallback_ip)

      conn
      |> put_req_header("x-forwarded-for", spoofed_ip)
      |> post("/api/auth/login", %{email: "audit-xff@example.com", password: "secret123"})
      |> json_response(200)

      row = latest_audit_row("user.login")

      assert row["user_id"] == user.id
      refute row["ip_address"] == spoofed_hash
      assert row["ip_address"] == fallback_hash
    end
  end

  describe "POST /api/auth/login per-account lockout" do
    setup do
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

      for _ <- 1..3 do
        post(conn, "/api/auth/login", %{email: "lockme@example.com", password: "wrong"})
      end

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

    test "exposes the user's handle so the SPA can link to /u/:handle", %{conn: conn} do
      user = insert(:user, handle: "ada_me")
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert %{"user" => returned_user} = json_response(conn, 200)
      assert returned_user["handle"] == "ada_me"
    end

    test "carries a pending email change, which is where the settings page reads it from", %{
      conn: conn
    } do
      # The serializer's take-list is a wire ALLOWLIST: a field the context sets
      # and the allowlist omits is dropped in silence, and the settings panel
      # simply never appears on reload. Nothing but a test at this boundary
      # notices — the unit tests, the decoder and the page all pass without it.
      user = insert(:user, email: "changing@example.com")

      {:ok, pending} =
        user
        |> Stacks.Accounts.pending_email_changeset(%{
          pending_email: "wanted@example.com",
          pending_email_token: Stacks.Accounts.sign_email_change_token(user.id),
          pending_email_sent_at: DateTime.utc_now(),
          pending_email_revert_token: Stacks.Accounts.sign_email_revert_token(user.id)
        })
        |> Core.Repo.update()

      {:ok, token, _} = Guardian.encode_and_sign(pending)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert %{"user" => returned_user} = json_response(conn, 200)
      assert returned_user["email"] == "changing@example.com"
      assert returned_user["pending_email"] == "wanted@example.com"
      assert returned_user["pending_email_sent_at"]

      refute Map.has_key?(returned_user, "pending_email_token"),
             "the confirmation credential must never reach the wire"

      refute Map.has_key?(returned_user, "pending_email_revert_token"),
             "the undo credential must never reach the wire"
    end

    # The settings profile form reads this endpoint to show what the account
    # actually holds. A field missing from `ProtoJSON`'s wire allowlist is
    # dropped silently, and the form then renders it blank over a stored value —
    # which is exactly how a saved website URL came back empty on every visit.
    test "carries every account field the settings profile form edits", %{conn: conn} do
      user =
        insert(:user,
          email: "fields@example.com",
          display_name: "Ada Lovelace",
          handle: "ada_fields",
          country_code: "GB",
          city: "London",
          website_url: "https://ada.dev"
        )

      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert %{"user" => returned_user} = json_response(conn, 200)

      assert %{
               "email" => "fields@example.com",
               "display_name" => "Ada Lovelace",
               "handle" => "ada_fields",
               "country_code" => "GB",
               "city" => "London",
               "website_url" => "https://ada.dev"
             } = returned_user
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

  describe "JWT lifecycle on GET /api/auth/me" do
    test "an expired JWT is rejected with 401", %{conn: conn} do
      user = insert(:user, email: "expired@example.com", email_confirmed: true)
      {:ok, expired_token, _claims} = Guardian.encode_and_sign(user, %{}, ttl: {-1, :hour})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{expired_token}")
        |> get("/api/auth/me")

      assert json_response(conn, 401)
    end

    test "the same JWT is rejected with 401 after logout", %{conn: conn} do
      user = insert(:user, email: "revoke@example.com", email_confirmed: true)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      pre_logout =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert json_response(pre_logout, 200)

      logout_conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/auth/logout")

      assert response(logout_conn, 204)

      post_logout =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert json_response(post_logout, 401)
    end
  end

  describe "POST /api/auth/refresh" do
    test "returns 200 with a fresh, different, verifiable token and a user object",
         %{conn: conn} do
      user = insert(:user, email: "refresh-happy@example.com", email_confirmed: true)
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user)

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"token" => new_token, "user" => returned_user} = json_response(refresh_conn, 200)

      assert is_binary(new_token)
      assert new_token != ""
      assert new_token != old_token

      assert returned_user["email"] == "refresh-happy@example.com"

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

      stale_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> get("/api/auth/me")

      assert json_response(stale_conn, 401)
    end

    test "returns 401 when the token has been revoked (logged out)", %{conn: conn} do
      user = insert(:user, email: "refresh-revoked@example.com", email_confirmed: true)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

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

    # when Guardian.revoke fails during refresh the action still
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

      assert %{"token" => new_token} = json_response(refresh_conn, 200)
      assert is_binary(new_token) and new_token != ""

      assert_receive {:telemetry, [:stacks, :auth, :refresh, :revoke_failed], %{count: 1}, %{}}
    end

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

      assert new_token != old_token

      assert {:ok, new_claims} = Guardian.decode_and_verify(new_token)
      assert new_claims["sst"] == original_sst
    end

    test "refresh past the absolute cap returns 401 session_expired and revokes the old token",
         %{conn: conn} do
      user = insert(:user, email: "refresh-cap-exceeded@example.com", email_confirmed: true)
      now = System.system_time(:second)
      old_sst = now - 8 * 24 * 3600
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user, %{"sst" => old_sst})

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"error" => "session_expired"} = json_response(refresh_conn, 401)

      stale_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> get("/api/auth/me")

      assert json_response(stale_conn, 401)
    end

    test "emits [:stacks,:auth,:session,:expired] with reason:lifetime_cap past the cap",
         %{conn: conn} do
      user = insert(:user, email: "refresh-cap-telemetry@example.com", email_confirmed: true)
      now = System.system_time(:second)
      old_sst = now - 8 * 24 * 3600
      {:ok, old_token, _claims} = Guardian.encode_and_sign(user, %{"sst" => old_sst})

      test_pid = self()
      handler_id = "test-session-expired-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:stacks, :auth, :session, :expired],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      refresh_conn =
        conn
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post("/api/auth/refresh")

      assert %{"error" => "session_expired"} = json_response(refresh_conn, 401)

      assert_receive {:telemetry, [:stacks, :auth, :session, :expired], %{count: 1},
                      %{reason: :lifetime_cap}}
    end

    test "minting a token stamps a session-start anchor (sst) approximately now",
         %{conn: _conn} do
      user = insert(:user, email: "sst-stamp@example.com", email_confirmed: true)
      now = System.system_time(:second)

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

      refresh_conn =
        conn
        |> Guardian.Plug.put_current_resource(user)
        |> Guardian.Plug.put_current_token(old_token)
        |> Guardian.Plug.put_current_claims(%{"sub" => to_string(user.id)})
        |> AuthController.refresh(%{})

      assert %{"token" => new_token} = json_response(refresh_conn, 200)

      assert {:ok, new_claims} = Guardian.decode_and_verify(new_token)
      assert is_integer(new_claims["sst"])
      assert_in_delta new_claims["sst"], now, 5
    end
  end

  describe "refresh-token families" do
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

      assert new_claims["family_id"] == old_claims["family_id"]
      assert new_claims["jti"] != old_claims["jti"]

      assert Repo.aggregate(AuthTokenFamily, :count, :family_id) == 1

      family = Repo.get(AuthTokenFamily, old_claims["family_id"])
      assert family.current_jti == new_claims["jti"]
      refute family.current_jti == old_claims["jti"]
    end

    test "a legacy token with no family_id is adopted into a family on refresh (no 500)",
         %{conn: conn} do
      user =
        insert(:user, email: "family-legacy@example.com", email_confirmed: true)

      {:ok, old_token, _claims} = Guardian.encode_and_sign(user)

      refresh_conn =
        conn
        |> Guardian.Plug.put_current_resource(user)
        |> Guardian.Plug.put_current_token(old_token)
        |> Guardian.Plug.put_current_claims(%{"sub" => to_string(user.id)})
        |> AuthController.refresh(%{})

      assert %{"token" => new_token} = json_response(refresh_conn, 200)
      assert {:ok, new_claims} = Guardian.decode_and_verify(new_token)

      assert is_binary(new_claims["family_id"])
      family = Repo.get(AuthTokenFamily, new_claims["family_id"])
      assert family
      assert family.current_jti == new_claims["jti"]
      assert family.user_id == user.id
    end
  end

  describe "reuse detection & family revocation" do
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

      refresh_b =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_b, 200)

      refresh_c =
        conn |> put_req_header("authorization", "Bearer #{token_b}") |> post("/api/auth/refresh")

      assert %{"token" => token_c} = json_response(refresh_c, 200)

      replay_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> get("/api/auth/me")

      assert json_response(replay_conn, 401)

      family = Repo.get(AuthTokenFamily, family_id)
      assert family.revoked_at

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

      refresh_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_conn, 200)
      assert {:ok, claims_b} = Guardian.decode_and_verify(token_b)

      logout_conn =
        conn |> put_req_header("authorization", "Bearer #{token_b}") |> delete("/api/auth/logout")

      assert response(logout_conn, 204)

      after_conn =
        conn |> put_req_header("authorization", "Bearer #{token_b}") |> get("/api/auth/me")

      assert json_response(after_conn, 401)

      family = Repo.get(AuthTokenFamily, claims_b["family_id"])
      assert family.revoked_at
    end
  end

  describe "rotation grace window" do
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
      assert family.previous_jti == claims_a["jti"]
      assert family.current_jti == claims_b["jti"]
      assert family.rotated_at
      assert DateTime.compare(family.rotated_at, before) in [:gt, :eq]
    end

    test "the just-rotated old token is honoured by the family gate within grace (no false burn)",
         %{conn: conn} do
      {token_a, claims_a} = login_token_g!(conn, "grace-inflight@example.com")

      refresh_conn =
        conn |> put_req_header("authorization", "Bearer #{token_a}") |> post("/api/auth/refresh")

      assert %{"token" => token_b} = json_response(refresh_conn, 200)
      {:ok, claims_b} = Guardian.decode_and_verify(token_b)

      assert :ok =
               Accounts.check_token_family(
                 claims_b["family_id"],
                 claims_a["jti"],
                 claims_a["sub"]
               )

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

    test "no_enumeration: sent, suppressed and unknown addresses get one identical answer" do
      insert(:user, email: "gets-a-link@example.com")
      throttled = insert(:user, email: "gets-nothing@example.com")
      saturate_email_limit(throttled.id)

      sent = forgot_password_response("gets-a-link@example.com")
      suppressed = forgot_password_response("gets-nothing@example.com")
      unknown = forgot_password_response("nobody-at-all@example.com")

      assert sent == suppressed,
             """
             A reset that was sent and one the limiter swallowed answered differently.
             The context now knows which happened; the wire must not.
             sent:       #{inspect(sent)}
             suppressed: #{inspect(suppressed)}
             """

      assert suppressed == unknown,
             """
             A registered address and an address with no account answered differently.
             suppressed: #{inspect(suppressed)}
             unknown:    #{inspect(unknown)}
             """

      assert sent.status == 200
      assert {"content-type", "application/json; charset=utf-8"} in sent.headers
    end

    test "the suppressed request really was suppressed — the reply is uniform, the effect is not" do
      throttled = insert(:user, email: "provably-throttled@example.com")
      saturate_email_limit(throttled.id)

      assert %{status: 200} = forgot_password_response("provably-throttled@example.com")

      assert is_nil(Repo.reload!(throttled).password_reset_token),
             "precondition for the uniformity test above: this address must be one " <>
               "the platform answered without sending anything, or the pair it " <>
               "compares are both ordinary sends"
    end
  end

  describe "POST /api/auth/resend-confirmation" do
    test "no_enumeration: unconfirmed, confirmed, capped and unknown addresses get one identical answer" do
      insert(:unconfirmed_user, email: "waiting@example.com")
      insert(:user, email: "already-in@example.com", email_confirmed: true)

      too_old = insert(:unconfirmed_user, email: "long-abandoned@example.com")

      {1, _} =
        Repo.update_all(from(u in Accounts.User, where: u.id == ^too_old.id),
          set: [
            created_at:
              DateTime.add(
                DateTime.utc_now(),
                -(Accounts.unverified_account_max_lifetime_seconds() + 60),
                :second
              )
          ]
        )

      unconfirmed = resend_response("waiting@example.com")
      confirmed = resend_response("already-in@example.com")
      unknown = resend_response("nobody-at-all@example.com")
      capped = resend_response("long-abandoned@example.com")

      assert unconfirmed == confirmed,
             """
             An unconfirmed address and a confirmed address answered differently.
             unconfirmed: #{inspect(unconfirmed)}
             confirmed:   #{inspect(confirmed)}
             """

      assert confirmed == unknown,
             """
             A real address and an address with no account answered differently.
             confirmed: #{inspect(confirmed)}
             unknown:   #{inspect(unknown)}
             """

      assert unknown == capped,
             """
             An account past the resend cap answered differently from an unknown address.
             unknown: #{inspect(unknown)}
             capped:  #{inspect(capped)}
             """

      assert unconfirmed.status == 200
      assert unconfirmed.body =~ "fresh link"

      assert {"content-type", "application/json; charset=utf-8"} in unconfirmed.headers
    end

    test "an unconfirmed account is issued a NEW link, and the old one stops working" do
      user = insert(:unconfirmed_user, email: "waiting@example.com")
      old_token = user.email_confirmation_token
      assert Accounts.confirmation_link_live?(old_token), "fixture must start with a live link"

      assert %{status: 200} = resend_response("waiting@example.com")

      new_token = Repo.reload!(user).email_confirmation_token
      refute new_token == old_token, "resend must re-sign, not re-send the same token"

      assert [%Oban.Job{args: %{"template" => "registration_confirmation"} = args}] =
               Repo.all(Oban.Job)

      assert args["params"]["token"] == new_token,
             "the email must carry the token that was just stored"

      assert {:error, :invalid} = Stacks.Email.confirm_email(old_token)
      assert {:ok, confirmed} = Stacks.Email.confirm_email(new_token)
      assert confirmed.email_confirmed
    end

    test "an already-confirmed account is sent nothing, and stays confirmed" do
      user = insert(:user, email: "already-in@example.com", email_confirmed: true)

      assert %{status: 200} = resend_response("already-in@example.com")

      assert Repo.all(Oban.Job) == [], "a confirmed reader has no link to be sent"
      assert Repo.reload!(user).email_confirmed, "a resend must never un-confirm an account"
    end

    test "an unknown address is sent nothing" do
      assert %{status: 200} = resend_response("nobody-at-all@example.com")
      assert Repo.all(Oban.Job) == []
    end

    test "an address the email limiter has throttled answers exactly like an unknown one" do
      throttled = insert(:unconfirmed_user, email: "throttled@example.com")
      original = throttled.email_confirmation_token
      saturate_email_limit(throttled.id)

      suppressed = resend_response("throttled@example.com")
      unknown = resend_response("nobody-at-all@example.com")

      assert suppressed == unknown,
             """
             A real address whose link the limiter swallowed answered differently
             from an address with no account.
             suppressed: #{inspect(suppressed)}
             unknown:    #{inspect(unknown)}
             """

      assert Repo.reload!(throttled).email_confirmation_token == original,
             "precondition: the throttled address must have been sent nothing, or " <>
               "the comparison above is between two ordinary sends"
    end

    test "returns 422 when the email param is missing", %{conn: conn} do
      conn = post(conn, "/api/auth/resend-confirmation", %{})

      assert json_response(conn, 422)
    end

    test "rate limiting is not an oracle: a real and an unknown address are throttled identically" do
      insert(:unconfirmed_user, email: "waiting@example.com")

      original = Application.get_env(:core, :rate_limiting_enabled)
      original_limit = Application.get_env(:core, :rate_limit_auth)
      Application.put_env(:core, :rate_limiting_enabled, true)
      Application.put_env(:core, :rate_limit_auth, 5)

      on_exit(fn ->
        Application.put_env(:core, :rate_limiting_enabled, original)

        if original_limit,
          do: Application.put_env(:core, :rate_limit_auth, original_limit),
          else: Application.delete_env(:core, :rate_limit_auth)

        :ets.delete_all_objects(:rate_limiter)
      end)

      statuses = fn email ->
        :ets.delete_all_objects(:rate_limiter)
        Enum.map(1..8, fn _ -> resend_response(email).status end)
      end

      real = statuses.("waiting@example.com")
      unknown = statuses.("nobody-at-all@example.com")

      assert real == unknown,
             """
             The limiter throttled a real address on a different request than an unknown one.
             real:    #{inspect(real)}
             unknown: #{inspect(unknown)}
             """

      assert 429 in real, "expected the :auth bucket to reject once the limit was passed"
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

    test "per-Fly-Client-IP isolation: exhausting one client does not block another",
         %{conn: conn} do
      client_a = put_req_header(conn, "fly-client-ip", "10.99.2.1")
      client_b = put_req_header(conn, "fly-client-ip", "10.99.2.2")

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
      reg_conn =
        post(conn, "/api/auth/register", %{email: "flow@example.com", password: "password123"})

      assert %{"message" => "confirmation_email_sent"} = json_response(reg_conn, 201)

      pre_confirm_conn =
        post(conn, "/api/auth/login", %{email: "flow@example.com", password: "password123"})

      assert %{"error" => "email_unconfirmed"} = json_response(pre_confirm_conn, 403)

      user = Stacks.Accounts.get_user_by_email("flow@example.com")

      {:ok, _} =
        user
        |> Accounts.email_confirmation_changeset(%{
          email_confirmed: true,
          email_confirmation_token: nil
        })
        |> Core.Repo.update()

      login_conn =
        post(conn, "/api/auth/login", %{email: "flow@example.com", password: "password123"})

      assert %{"token" => login_token} = json_response(login_conn, 200)

      me_conn =
        conn
        |> put_req_header("authorization", "Bearer #{login_token}")
        |> get("/api/auth/me")

      assert %{"user" => returned_user} = json_response(me_conn, 200)
      assert returned_user["email"] == "flow@example.com"

      logout_conn =
        conn
        |> put_req_header("authorization", "Bearer #{login_token}")
        |> delete("/api/auth/logout")

      assert response(logout_conn, 204)
    end
  end

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
