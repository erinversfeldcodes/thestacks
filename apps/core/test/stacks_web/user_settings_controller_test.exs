defmodule StacksWeb.UserSettingsControllerTest do
  @moduledoc """
  Tests for the user-settings endpoints (profile, location, password,
  notifications, profile visibility). Age verification is no longer a user
  setting (ADR-020) — self-declaration was removed.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "PUT /api/settings/profile" do
    test "updates display_name and website_url", %{conn: conn} do
      user = insert(:user, display_name: "Old Name")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{
          display_name: "New Name",
          website_url: "https://example.com"
        })

      assert %{"display_name" => "New Name", "website_url" => "https://example.com"} =
               json_response(conn, 200)
    end

    test "updates email when current_password is correct", %{conn: conn} do
      user = insert(:user, email: "old@example.com")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{
          email: "new@example.com",
          current_password: "password123"
        })

      assert %{"email" => "new@example.com"} = json_response(conn, 200)
    end

    test "returns 422 when changing email with wrong current_password", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{email: "new@example.com", current_password: "wrong"})

      assert %{"error" => "invalid_current_password"} = json_response(conn, 422)
    end

    test "returns 422 when changing email without current_password", %{conn: conn} do
      user = insert(:user)
      conn = conn |> auth_conn(user) |> put("/api/settings/profile", %{email: "new@example.com"})
      assert %{"error" => "invalid_current_password"} = json_response(conn, 422)
    end

    test "returns 422 when website_url exceeds 500 characters", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{website_url: String.duplicate("a", 501)})

      assert %{"errors" => %{"website_url" => [_]}} = json_response(conn, 422)
    end

    test "sets a new handle and echoes the normalised (lowercased) value", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{handle: "AdaLovelace"})

      assert %{"handle" => "adalovelace"} = json_response(conn, 200)
    end

    test "returns a 422 handle field error for a reserved handle", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{handle: "settings"})

      assert %{"errors" => %{"handle" => [_ | _]}} = json_response(conn, 422)
    end

    test "returns a 422 handle field error for an already-taken handle (case-insensitive)",
         %{conn: conn} do
      insert(:user, handle: "already_taken")
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{handle: "ALREADY_TAKEN"})

      assert %{"errors" => %{"handle" => [_ | _]}} = json_response(conn, 422)
    end

    test "returns a 422 handle field error for a malformed handle", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{handle: "ab"})

      assert %{"errors" => %{"handle" => [_ | _]}} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/settings/profile", %{display_name: "X"})
      assert json_response(conn, 401)
    end

    test "saves a display_name change when email equals the current email and no password (CG-1)",
         %{conn: conn} do
      # The settings UI sends the current email on every profile save; a same-email
      # payload must NOT be treated as an email change and must NOT demand a
      # current_password.
      user = insert(:user, email: "same@example.com", display_name: "Old Name")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{
          email: "same@example.com",
          display_name: "New Name",
          current_password: ""
        })

      assert %{"display_name" => "New Name", "email" => "same@example.com"} =
               json_response(conn, 200)
    end

    test "still 422s a genuinely different email without current_password (CG-1 guard)",
         %{conn: conn} do
      user = insert(:user, email: "old@example.com")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{email: "different@example.com", current_password: ""})

      assert %{"error" => "invalid_current_password"} = json_response(conn, 422)
    end

    test "handle \"\" is treated as no change and does not 500 (NOT NULL handle column)",
         %{conn: conn} do
      # Regression: an empty handle casts to a nil change that validate_handle
      # skips, which — without a guard — writes NULL into the NOT NULL handle
      # column (Postgrex 23502 → 500). The settings UI always sends handle, so a
      # display-name-only save must succeed with the handle unchanged.
      user = insert(:user)
      original_handle = user.handle

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile", %{display_name: "New Name", handle: ""})

      assert %{"display_name" => "New Name", "handle" => ^original_handle} =
               json_response(conn, 200)
    end
  end

  describe "PUT /api/settings/location" do
    test "updates country_code and city", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/location", %{country_code: "GB", city: "London"})

      assert %{"country_code" => "GB", "city" => "London"} = json_response(conn, 200)
    end

    test "returns 422 for invalid country_code length", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/location", %{country_code: "GBR"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/settings/location", %{country_code: "GB"})
      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/settings/password" do
    test "changes password with valid current_password", %{conn: conn} do
      # Factory default password_hash is Argon2 hash of "password123"
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/password", %{
          current_password: "password123",
          new_password: "newpassword456"
        })

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 422 on wrong current_password", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/password", %{
          current_password: "not_the_right_password",
          new_password: "newpassword456"
        })

      assert %{"error" => "invalid_current_password"} = json_response(conn, 422)
    end

    test "returns 422 when new_password is shorter than 8 characters", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/password", %{current_password: "password123", new_password: "short"})

      assert %{"errors" => %{"password" => [_]}} = json_response(conn, 422)
    end

    test "returns 422 when parameters are missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/password", %{})

      assert %{"error" => "current_password and new_password are required"} =
               json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/settings/password", %{current_password: "x", new_password: "y"})
      assert json_response(conn, 401)
    end

    # Issue #179, Phase 2b: a successful password change logs the user out
    # everywhere — every one of the user's tokens (and families) is revoked, so
    # a stolen/leaked token cannot outlive the credential it was minted under.
    test "logs the user out everywhere (existing token 401s after the change)",
         %{conn: conn} do
      # Factory default password_hash is Argon2 hash of "password123".
      user = insert(:user)
      {:ok, token, _} = Guardian.encode_and_sign(user)

      # Sanity: the token authenticates BEFORE the password change.
      before_conn =
        conn |> put_req_header("authorization", "Bearer #{token}") |> get("/api/auth/me")

      assert json_response(before_conn, 200)

      change_conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put("/api/settings/password", %{
          current_password: "password123",
          new_password: "newpassword456"
        })

      assert %{"ok" => true} = json_response(change_conn, 200)

      # Logged out everywhere: the same token no longer authenticates.
      after_conn =
        conn |> put_req_header("authorization", "Bearer #{token}") |> get("/api/auth/me")

      assert json_response(after_conn, 401)
    end
  end

  describe "PUT /api/settings/notifications" do
    test "toggles notification preferences", %{conn: conn} do
      user = insert(:user, notify_marketplace: false)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/notifications", %{notify_marketplace: true})

      assert %{"notify_marketplace" => true} = json_response(conn, 200)
    end

    test "toggles all four notification fields simultaneously", %{conn: conn} do
      user =
        insert(:user,
          notify_wishlist_availability: false,
          notify_marketplace: false,
          notify_group_invitations: false,
          notify_event_matches: false
        )

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/notifications", %{
          notify_wishlist_availability: true,
          notify_marketplace: true,
          notify_group_invitations: true,
          notify_event_matches: true
        })

      assert %{
               "notify_wishlist_availability" => true,
               "notify_marketplace" => true,
               "notify_group_invitations" => true,
               "notify_event_matches" => true
             } = json_response(conn, 200)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/settings/notifications", %{notify_marketplace: true})
      assert json_response(conn, 401)
    end

    test "returns 422 when a notify_* value is not a boolean", %{conn: conn} do
      # A non-boolean value is a cast error on notifications_changeset, so the
      # controller returns 422 with field errors. (Only UNKNOWN keys are silently
      # ignored — a known key with an uncastable value is a real 422.)
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/notifications", %{notify_marketplace: "banana"})

      assert %{"errors" => %{"notify_marketplace" => [_ | _]}} = json_response(conn, 422)
    end
  end

  describe "GET /api/settings/notifications" do
    test "returns the four notify_* fields for the authed user", %{conn: conn} do
      user = insert(:user)

      conn = conn |> auth_conn(user) |> get("/api/settings/notifications")

      assert %{
               "notify_wishlist_availability" => _,
               "notify_marketplace" => _,
               "notify_group_invitations" => _,
               "notify_event_matches" => _
             } = json_response(conn, 200)
    end

    test "reflects stored DB values, not schema defaults", %{conn: conn} do
      # Invert every field away from its schema default so a hardcoded-default
      # response would fail: defaults are wishlist=false, marketplace=true,
      # group_invitations=true, event_matches=false.
      user =
        insert(:user,
          notify_wishlist_availability: true,
          notify_marketplace: false,
          notify_group_invitations: false,
          notify_event_matches: true
        )

      conn = conn |> auth_conn(user) |> get("/api/settings/notifications")

      assert %{
               "notify_wishlist_availability" => true,
               "notify_marketplace" => false,
               "notify_group_invitations" => false,
               "notify_event_matches" => true
             } = json_response(conn, 200)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, "/api/settings/notifications")
      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/settings/profile_visibility" do
    test "returns 200 and sets profile_visibility to platform", %{conn: conn} do
      user = insert(:user, profile_visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile_visibility", %{profile_visibility: "platform"})

      assert %{"profile_visibility" => "platform"} = json_response(conn, 200)
    end

    test "returns 200 and sets profile_visibility to owner", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile_visibility", %{profile_visibility: "owner"})

      assert %{"profile_visibility" => "owner"} = json_response(conn, 200)
    end

    test "returns 422 when value is invalid", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile_visibility", %{profile_visibility: "nonsense"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 when parameter is missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/settings/profile_visibility", %{})

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = put(conn, "/api/settings/profile_visibility", %{profile_visibility: "platform"})
      assert json_response(conn, 401)
    end
  end
end
