defmodule StacksWeb.TestHelperControllerTest do
  @moduledoc """
  Guards the test-only confirmation-token endpoint (Issue #124, Phase 3).

  This endpoint leaks an account-activation token, so the security-critical
  property under test is that it is *disabled* unless the server env flag
  `STACKS_E2E_TEST_HELPERS == "1"` is set. In production the flag is never
  set, so the route returns 404 for every request.

  `async: false` because the tests mutate a process-global environment
  variable; running serially keeps them from leaking into async tests.
  """
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  @flag "STACKS_E2E_TEST_HELPERS"

  setup do
    original = System.get_env(@flag)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(@flag)
        value -> System.put_env(@flag, value)
      end
    end)

    :ok
  end

  describe "GET /api/test/confirmation-token with the flag OFF (production posture)" do
    setup do
      System.delete_env(@flag)
      :ok
    end

    test "returns 404 and never exposes the confirmation token", %{conn: conn} do
      user =
        insert(:user,
          email: "off@example.com",
          email_confirmed: false,
          email_confirmation_token: "super-secret-token-off"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
      refute conn.resp_body =~ "super-secret-token-off"
    end

    test "returns 404 even when the flag is present but not exactly \"1\"", %{conn: conn} do
      System.put_env(@flag, "true")

      user =
        insert(:user,
          email: "notone@example.com",
          email_confirmed: false,
          email_confirmation_token: "super-secret-token-notone"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
      refute conn.resp_body =~ "super-secret-token-notone"
    end
  end

  describe "GET /api/test/confirmation-token with the flag ON" do
    setup do
      System.put_env(@flag, "1")
      :ok
    end

    test "returns 200 with ONLY the confirmation token for a seeded unconfirmed user", %{
      conn: conn
    } do
      user =
        insert(:user,
          email: "e2e-on@thestacks.test",
          email_confirmed: false,
          email_confirmation_token: "super-secret-token-on"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      # Exact-map assertion proves the body contains the token and nothing else
      # (no email, no password_hash, no id, no other PII).
      assert json_response(conn, 200) == %{"token" => "super-secret-token-on"}
    end

    test "email lookup is case-insensitive (matches Accounts.get_user_by_email/1)", %{conn: conn} do
      insert(:user,
        email: "e2e-mixed@thestacks.test",
        email_confirmed: false,
        email_confirmation_token: "super-secret-token-mixed"
      )

      conn = get(conn, "/api/test/confirmation-token", email: "E2E-Mixed@Thestacks.Test")

      assert json_response(conn, 200) == %{"token" => "super-secret-token-mixed"}
    end

    test "returns 404 for an unknown (but e2e-domain) email", %{conn: conn} do
      conn = get(conn, "/api/test/confirmation-token", email: "e2e-nobody@thestacks.test")

      assert conn.status == 404
    end

    test "returns 404 for a user that has no confirmation token", %{conn: conn} do
      user =
        insert(:user,
          email: "e2e-confirmed@thestacks.test",
          email_confirmed: true,
          email_confirmation_token: nil
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
    end

    test "returns 404 when the email param is missing", %{conn: conn} do
      conn = get(conn, "/api/test/confirmation-token")

      assert conn.status == 404
    end

    # ── Scoping: only e2e/test-domain emails resolve (Issue #124 PE-gate) ──────
    #
    # Even with the flag ON (as on a public preview app, especially one carrying
    # the `preview-real-email` label), the helper must NEVER leak a real user's
    # confirmation token. A real user's email is never in the reserved
    # `.test` TLD, so any non-`@thestacks.test` email is treated as not-found.

    test "returns 404 for a NON-e2e-domain email even when that user exists with a token", %{
      conn: conn
    } do
      user =
        insert(:user,
          email: "real@gmail.com",
          email_confirmed: false,
          email_confirmation_token: "super-secret-real-user-token"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
      # The real user's activation token must never appear in the response.
      refute conn.resp_body =~ "super-secret-real-user-token"
    end

    test "returns 404 for a lookalike domain (e.g. thestacks.test.evil.com)", %{conn: conn} do
      user =
        insert(:user,
          email: "victim@thestacks.test.evil.com",
          email_confirmed: false,
          email_confirmation_token: "super-secret-lookalike-token"
        )

      conn = get(conn, "/api/test/confirmation-token", email: user.email)

      assert conn.status == 404
      refute conn.resp_body =~ "super-secret-lookalike-token"
    end
  end

  # ── PUT /api/test/age-verification (ADR-020) ─────────────────────────────────
  #
  # E2E/tests use this to create an age-verified user without a real KYC
  # provider. Scoped to `@thestacks.test` emails ONLY — the same guard as the
  # confirmation-token endpoint — so it can never flip a real account.
  describe "PUT /api/test/age-verification with the flag ON" do
    setup do
      System.put_env(@flag, "1")
      :ok
    end

    test "verified: true records provider verification and returns ok", %{conn: conn} do
      user = insert(:user, email: "e2e-av@thestacks.test", age_verified: false)

      conn =
        put(conn, "/api/test/age-verification", %{email: user.email, verified: true})

      assert json_response(conn, 200) == %{"ok" => true}

      updated = Stacks.Accounts.get_user!(user.id)
      assert updated.age_verified == true
      assert updated.age_verification_provider == "e2e_test_helper"
      assert updated.age_verified_at != nil
    end

    test "verified: false revokes verification", %{conn: conn} do
      user =
        insert(:user,
          email: "e2e-av-off@thestacks.test",
          age_verified: true,
          age_verification_provider: "e2e_test_helper"
        )

      conn =
        put(conn, "/api/test/age-verification", %{email: user.email, verified: false})

      assert json_response(conn, 200) == %{"ok" => true}

      updated = Stacks.Accounts.get_user!(user.id)
      assert updated.age_verified == false
      assert updated.age_verification_provider == nil
    end

    test "returns 404 for a NON-e2e-domain email even if the user exists", %{conn: conn} do
      user = insert(:user, email: "real-av@gmail.com", age_verified: false)

      conn =
        put(conn, "/api/test/age-verification", %{email: user.email, verified: true})

      assert conn.status == 404
      assert Stacks.Accounts.get_user!(user.id).age_verified == false
    end

    test "returns 404 for an unknown (but e2e-domain) email", %{conn: conn} do
      conn =
        put(conn, "/api/test/age-verification", %{
          email: "e2e-nobody@thestacks.test",
          verified: true
        })

      assert conn.status == 404
    end

    test "returns 404 when params are missing/malformed", %{conn: conn} do
      conn = put(conn, "/api/test/age-verification", %{email: "e2e-x@thestacks.test"})
      assert conn.status == 404
    end
  end

  describe "PUT /api/test/age-verification with the flag OFF (production posture)" do
    setup do
      System.delete_env(@flag)
      :ok
    end

    test "returns 404 and does not flip verification", %{conn: conn} do
      user = insert(:user, email: "e2e-av-flagoff@thestacks.test", age_verified: false)

      conn =
        put(conn, "/api/test/age-verification", %{email: user.email, verified: true})

      assert conn.status == 404
      assert Stacks.Accounts.get_user!(user.id).age_verified == false
    end
  end

  # ── Rate limiting (flag ON) ─────────────────────────────────────────────────
  #
  # On a public preview the endpoint is reachable, so it must be rate-limited
  # per IP to bound brute-force user-enumeration / token-harvesting attempts.
  describe "GET /api/test/confirmation-token rate limiting (flag ON)" do
    setup do
      System.put_env(@flag, "1")

      # Rate limiting is disabled in the test config by default; enable it and
      # pin a tiny limit so the boundary can be exercised with a short loop.
      original_enabled = Application.get_env(:core, :rate_limiting_enabled)
      original_limit = Application.get_env(:core, :rate_limit_e2e_helper)
      Application.put_env(:core, :rate_limiting_enabled, true)
      Application.put_env(:core, :rate_limit_e2e_helper, 3)

      on_exit(fn ->
        Application.put_env(:core, :rate_limiting_enabled, original_enabled)

        if original_limit do
          Application.put_env(:core, :rate_limit_e2e_helper, original_limit)
        else
          Application.delete_env(:core, :rate_limit_e2e_helper)
        end

        if :ets.whereis(:rate_limiter) != :undefined do
          :ets.delete_all_objects(:rate_limiter)
        end
      end)

      :ok
    end

    test "returns 429 once the per-IP limit is exceeded", %{conn: conn} do
      insert(:user,
        email: "e2e-rl@thestacks.test",
        email_confirmed: false,
        email_confirmation_token: "super-secret-token-rl"
      )

      # The first 3 requests (limit pinned to 3) from this IP are allowed.
      for _ <- 1..3 do
        resp = get(conn, "/api/test/confirmation-token", email: "e2e-rl@thestacks.test")
        assert resp.status == 200
      end

      # The 4th request from the same IP is blocked with 429.
      resp = get(conn, "/api/test/confirmation-token", email: "e2e-rl@thestacks.test")

      assert resp.status == 429
      assert Jason.decode!(resp.resp_body)["error"] == "rate_limit_exceeded"
      assert get_resp_header(resp, "retry-after") == ["60"]
    end
  end
end
