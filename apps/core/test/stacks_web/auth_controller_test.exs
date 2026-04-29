defmodule StacksWeb.AuthControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian

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
      conn = put_req_header(conn, "x-forwarded-for", "10.99.1.1")

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
      conn = put_req_header(conn, "x-forwarded-for", "10.99.1.2")

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
