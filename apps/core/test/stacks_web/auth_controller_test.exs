defmodule StacksWeb.AuthControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  describe "POST /api/auth/register" do
    test "creates user and returns JWT", %{conn: conn} do
      params = %{email: "new@example.com", password: "password123"}
      conn = post(conn, "/api/auth/register", params)

      assert %{"token" => token, "user" => user} = json_response(conn, 201)
      assert is_binary(token)
      assert user["email"] == "new@example.com"
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

  describe "integration: register → login → access protected route → logout" do
    test "full auth flow works end to end", %{conn: conn} do
      # Register
      reg_conn =
        post(conn, "/api/auth/register", %{email: "flow@example.com", password: "password123"})

      assert %{"token" => _token} = json_response(reg_conn, 201)

      # Login
      login_conn =
        post(conn, "/api/auth/login", %{email: "flow@example.com", password: "password123"})

      assert %{"token" => login_token} = json_response(login_conn, 200)

      # Access protected route
      me_conn =
        conn
        |> put_req_header("authorization", "Bearer #{login_token}")
        |> get("/api/auth/me")

      assert %{"user" => user} = json_response(me_conn, 200)
      assert user["email"] == "flow@example.com"

      # Logout
      logout_conn =
        conn
        |> put_req_header("authorization", "Bearer #{login_token}")
        |> delete("/api/auth/logout")

      assert response(logout_conn, 204)
    end
  end
end
