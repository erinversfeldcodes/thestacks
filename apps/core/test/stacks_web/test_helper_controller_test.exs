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

  alias Stacks.Books.ISBN
  alias Swoosh.Adapters.Local.Storage.Memory

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

  # ── GET /api/test/sent-emails (WS2 — prove the email was actually sent) ──────
  #
  # Reads the Swoosh Local mailbox so the E2E suite can assert an email was
  # delivered and extract its link. Same `@thestacks.test`-only scoping as the
  # other helpers — a real user's mail can never surface here.
  describe "GET /api/test/sent-emails with the flag ON" do
    setup do
      System.put_env(@flag, "1")
      :ok
    end

    test "returns emails delivered to the given test-domain address", %{conn: conn} do
      addr = "e2e-inbox@thestacks.test"

      push_email(addr, "Confirm your email — The Stacks",
        html: "<a href=\"https://x/api/auth/confirm/tok-123\">Confirm</a>",
        text: "confirm: https://x/api/auth/confirm/tok-123"
      )

      conn = get(conn, "/api/test/sent-emails", email: addr)

      assert %{"emails" => [email]} = json_response(conn, 200)
      assert email["to"] == [addr]
      assert email["subject"] == "Confirm your email — The Stacks"
      assert email["html_body"] =~ "/api/auth/confirm/tok-123"
      assert email["text_body"] =~ "/api/auth/confirm/tok-123"
    end

    test "only returns mail addressed to the requested address", %{conn: conn} do
      push_email("e2e-mine@thestacks.test", "Mine", html: "mine")
      push_email("e2e-other@thestacks.test", "Other", html: "other")

      conn = get(conn, "/api/test/sent-emails", email: "e2e-mine@thestacks.test")

      assert %{"emails" => [email]} = json_response(conn, 200)
      assert email["subject"] == "Mine"
    end

    test "returns 404 for a NON-e2e-domain email even if that address has mail", %{conn: conn} do
      push_email("real-inbox@gmail.com", "Real user mail", html: "secret-real-body")

      conn = get(conn, "/api/test/sent-emails", email: "real-inbox@gmail.com")

      assert conn.status == 404
      refute conn.resp_body =~ "secret-real-body"
    end

    test "returns 404 when the email param is missing", %{conn: conn} do
      conn = get(conn, "/api/test/sent-emails")
      assert conn.status == 404
    end
  end

  describe "GET /api/test/sent-emails with the flag OFF (production posture)" do
    setup do
      System.delete_env(@flag)
      :ok
    end

    test "returns 404", %{conn: conn} do
      push_email("e2e-flagoff@thestacks.test", "Should not be readable", html: "hidden-body")

      conn = get(conn, "/api/test/sent-emails", email: "e2e-flagoff@thestacks.test")

      assert conn.status == 404
      refute conn.resp_body =~ "hidden-body"
    end
  end

  defp push_email(to, subject, opts) do
    Swoosh.Email.new(
      from: {"The Stacks", "noreply@thestacks.app"},
      to: {"", to},
      subject: subject,
      html_body: Keyword.get(opts, :html),
      text_body: Keyword.get(opts, :text)
    )
    |> Memory.push()
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

  # ── POST /api/test/session (Issue #192 — mint a confirmed session) ─────────
  #
  # This endpoint MINTS AUTHENTICATION, so the security-critical properties are
  # the same as the other helpers (404 whenever the flag is not exactly "1")
  # plus a hard `.test`-domain allowlist on user creation: it must be
  # impossible to mint a session for a real (non-test-TLD) account, even on a
  # public preview where the flag is on.
  describe "POST /api/test/session with the flag ON" do
    setup do
      System.put_env(@flag, "1")
      :ok
    end

    test "mints a confirmed user whose token authenticates a real request", %{conn: conn} do
      conn = post(conn, "/api/test/session", %{})

      assert %{"email" => email, "token" => token} = json_response(conn, 201)
      assert String.ends_with?(email, "@thestacks.test")
      assert is_binary(token) and token != ""

      user = Stacks.Accounts.get_user_by_email(email)
      assert user, "minted user must exist as an ordinary op.users row"
      assert user.email_confirmed == true

      # The token must be a REAL session token minted via the same path as
      # AuthController.login — including the refresh-token family invariant
      # (Issue #179: every live access token is tracked by exactly one family).
      assert Core.Repo.get_by(Stacks.Accounts.AuthTokenFamily, user_id: user.id)

      # Proof the token authenticates: drive an :authenticated route with it.
      authed =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/placements/mine")

      assert json_response(authed, 200)
    end

    test "each call mints a distinct user (unique default email)", %{conn: conn} do
      first = json_response(post(conn, "/api/test/session", %{}), 201)
      second = json_response(post(build_conn(), "/api/test/session", %{}), 201)

      assert first["email"] != second["email"]
    end

    test "honours explicit email and display_name", %{conn: conn} do
      conn =
        post(conn, "/api/test/session", %{
          email: "e2e-mint-explicit@thestacks.test",
          display_name: "Minted Explicitly"
        })

      assert %{"email" => "e2e-mint-explicit@thestacks.test"} = json_response(conn, 201)

      user = Stacks.Accounts.get_user_by_email("e2e-mint-explicit@thestacks.test")
      assert user.display_name == "Minted Explicitly"
      assert user.email_confirmed == true
    end

    test "returns 404 and creates NO user for a non-test-domain email", %{conn: conn} do
      conn = post(conn, "/api/test/session", %{email: "real-person@gmail.com"})

      assert conn.status == 404
      refute conn.resp_body =~ "token"
      assert Stacks.Accounts.get_user_by_email("real-person@gmail.com") == nil
    end

    test "returns 404 for a lookalike domain (thestacks.test.evil.com)", %{conn: conn} do
      conn = post(conn, "/api/test/session", %{email: "victim@thestacks.test.evil.com"})

      assert conn.status == 404
      assert Stacks.Accounts.get_user_by_email("victim@thestacks.test.evil.com") == nil
    end

    test "returns 422 when the email is already taken", %{conn: conn} do
      insert(:user, email: "e2e-mint-taken@thestacks.test")

      conn = post(conn, "/api/test/session", %{email: "e2e-mint-taken@thestacks.test"})

      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "POST /api/test/session with the flag OFF (production posture)" do
    setup do
      System.delete_env(@flag)
      :ok
    end

    test "returns 404 and mints nothing", %{conn: conn} do
      conn = post(conn, "/api/test/session", %{email: "e2e-mint-off@thestacks.test"})

      assert conn.status == 404
      refute conn.resp_body =~ "token"
      assert Stacks.Accounts.get_user_by_email("e2e-mint-off@thestacks.test") == nil
    end

    test "returns 404 even when the flag is present but not exactly \"1\"", %{conn: conn} do
      System.put_env(@flag, "true")

      conn = post(conn, "/api/test/session", %{email: "e2e-mint-notone@thestacks.test"})

      assert conn.status == 404
      assert Stacks.Accounts.get_user_by_email("e2e-mint-notone@thestacks.test") == nil
    end
  end

  # ── POST /api/test/book-description (#284 — seed a description-bearing book) ──
  #
  # Deep search matches book DESCRIPTIONS, but the seed carries 0 books with a
  # non-empty description, so the E2E slice needs a helper to insert one. This
  # writes catalogue metadata only (no user data/PII) and inserts a fresh row, so
  # the security surface is just the flag gate (404 unless the flag is "1").
  describe "POST /api/test/book-description with the flag ON" do
    setup do
      System.put_env(@flag, "1")
      :ok
    end

    test "creates a public book whose description is full-text searchable", %{conn: conn} do
      conn =
        post(conn, "/api/test/book-description", %{
          title: "Zzyzx Deep Anchor",
          description: "A study of bioluminescent creatures of the deep sea."
        })

      assert %{"ok" => true, "book_id" => book_id, "title" => "Zzyzx Deep Anchor"} =
               json_response(conn, 201)

      book = Stacks.Books.get_book_detail(book_id)
      assert book.description == "A study of bioluminescent creatures of the deep sea."
      # Public + single primary edition so it surfaces on the platform search.
      assert book.visibility_tier == "public"
      assert length(book.editions) == 1

      # Deep search finds it by description; the default title scope does not.
      deep = Stacks.Books.search_books("bioluminescent", scope: :deep)
      assert book_id in Enum.map(deep, & &1.id)
      assert Stacks.Books.search_books("bioluminescent") == []
    end

    test "generates a unique valid ISBN when none is supplied", %{conn: conn} do
      first =
        json_response(
          post(conn, "/api/test/book-description", %{title: "A", description: "x"}),
          201
        )

      second =
        json_response(
          post(build_conn(), "/api/test/book-description", %{title: "B", description: "y"}),
          201
        )

      assert first["book_id"] != second["book_id"]

      isbn = Stacks.Books.get_book_detail(first["book_id"]).editions |> hd() |> Map.get(:isbn)
      assert ISBN.valid_isbn_checksum?(isbn)
    end

    test "auto-generated ISBN carries the recognisable E2E-seed block (Issue #297)", %{conn: conn} do
      %{"book_id" => book_id} =
        json_response(
          post(conn, "/api/test/book-description", %{title: "Marker", description: "z"}),
          201
        )

      isbn = Stacks.Books.get_book_detail(book_id).editions |> hd() |> Map.get(:isbn)

      # The reserved synthetic block (978-99999-…) flags the row as E2E-seeded so it
      # can never be confused with a verified catalogue ISBN; still a well-formed,
      # checksum-valid ISBN-13 so Books.create accepts it past the ISBN Hard Gate.
      assert String.starts_with?(isbn, "97899999")
      assert String.length(isbn) == 13
      assert ISBN.valid_isbn_checksum?(isbn)
    end

    test "honours an explicit ISBN", %{conn: conn} do
      conn =
        post(conn, "/api/test/book-description", %{
          title: "Explicit ISBN Book",
          description: "Deep description here.",
          isbn: "9781617295027"
        })

      %{"book_id" => book_id} = json_response(conn, 201)
      isbn = Stacks.Books.get_book_detail(book_id).editions |> hd() |> Map.get(:isbn)
      assert isbn == "9781617295027"
    end

    test "returns 422 for a malformed ISBN", %{conn: conn} do
      conn =
        post(conn, "/api/test/book-description", %{
          title: "Bad ISBN",
          description: "desc",
          isbn: "not-an-isbn"
        })

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 404 when required params are missing", %{conn: conn} do
      conn = post(conn, "/api/test/book-description", %{title: "No description"})
      assert conn.status == 404
    end
  end

  describe "POST /api/test/book-description with the flag OFF (production posture)" do
    setup do
      System.delete_env(@flag)
      :ok
    end

    test "returns 404 and creates no book", %{conn: conn} do
      before = Core.Repo.aggregate(Stacks.Books.Book, :count)

      conn =
        post(conn, "/api/test/book-description", %{title: "Off Book", description: "nope"})

      assert conn.status == 404
      assert Core.Repo.aggregate(Stacks.Books.Book, :count) == before
    end

    test "returns 404 even when the flag is present but not exactly \"1\"", %{conn: conn} do
      System.put_env(@flag, "true")

      conn =
        post(conn, "/api/test/book-description", %{title: "NotOne", description: "nope"})

      assert conn.status == 404
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
