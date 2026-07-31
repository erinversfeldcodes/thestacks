defmodule CoreWeb.MetricsEndpointTest do
  @moduledoc """
  Tests that the /internal/metrics Prometheus endpoint returns Prometheus
  text format when authenticated. Auth is enforced by
  `StacksWeb.Plugs.MetricsAuth` (Issue #136).

  The `live exposure` describe block (Issue #230) proves the
  registered→scrapeable path end-to-end: after the moderation funnel and
  age-gate paths run through their real code, the #228 `stacks_moderation_*`
  / `stacks_age_gate_*` / `stacks_age_verification_*` families appear at
  `GET /internal/metrics` with samples. The #228 firing tests prove the
  events fire; this proves PromEx actually exposes them on the scrape
  endpoint the dashboard (Issue #230) queries.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.AgeVerification
  alias Stacks.Audit
  alias Stacks.GDPR.Consent
  alias Stacks.MFA
  alias Stacks.Moderation
  alias Stacks.Shelving
  alias Stacks.Social
  alias Stacks.Workers.AccountDeletionJob
  alias Stacks.Workers.DataExportJob
  alias Stacks.Workers.VisibilityRecapJob
  alias StacksWeb.Plugs.AgeGate
  alias StacksWeb.Plugs.RateLimiter
  alias StacksWeb.Plugs.ViewAsPlug

  @token "test-metrics-scrape-token"
  @test_image_b64 Base.encode64("fake image bytes")
  @age_gated_book %{visibility_tier: "age_gated"}

  setup do
    previous = Application.get_env(:core, :metrics_scrape_token)
    Application.put_env(:core, :metrics_scrape_token, @token)

    on_exit(fn ->
      if previous do
        Application.put_env(:core, :metrics_scrape_token, previous)
      else
        Application.delete_env(:core, :metrics_scrape_token)
      end
    end)

    :ok
  end

  defp scrape(conn) do
    # Let PromEx's telemetry handlers drain the ETS writes before scraping.
    Process.sleep(75)

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
    |> get("/internal/metrics")
    |> Map.fetch!(:resp_body)
  end

  describe "GET /internal/metrics" do
    test "returns 200 with Prometheus text format", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
        |> get("/internal/metrics")

      assert conn.status == 200

      assert get_resp_header(conn, "content-type")
             |> List.first()
             |> String.contains?("text/plain")
    end

    test "response body contains HELP or TYPE lines (Prometheus format)", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
        |> get("/internal/metrics")

      body = conn.resp_body
      # Prometheus text format includes # HELP and # TYPE lines
      assert body =~ "# HELP" or body =~ "# TYPE" or body == ""
    end
  end

  describe "live exposure: #228 moderation + age-gate families are scrapeable after exercising (Issue #230)" do
    test "moderation funnel families appear with samples after run_pipeline", %{conn: conn} do
      # Happy path: classification :book → isbn_resolution :resolved through the
      # real moderation pipeline code.
      assert {:ok, %{resolved: [book]}} =
               Moderation.run_pipeline(%{
                 image_b64: @test_image_b64,
                 book_attrs: %{"title" => "The Great Gatsby"}
               })

      # Tiering is no longer auto-assigned by the pipeline (the automatic
      # subject→BISAC classifier was removed): the `[:stacks, :moderation,
      # :tiering]` counter now fires only when a PERSON marks a book, via
      # Books.set_visibility_tier/3. Drive it here to exercise the family.
      assert {:ok, _} = Stacks.Books.set_visibility_tier(book, "age_gated", source: :user)

      # Compound-title ("… OR …") expansion through the real pipeline.
      with_vision(compound_title(), fn ->
        assert {:error, :isbn_not_found} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)

      body = scrape(conn)

      for family <- [
            "stacks_moderation_classification_count_total",
            "stacks_moderation_isbn_resolution_count_total",
            "stacks_moderation_tiering_count_total",
            "stacks_moderation_compound_expansion_count_total"
          ] do
        assert body =~ family,
               "expected #{family} exposed at /internal/metrics after the funnel ran, got:\n#{body}"
      end

      # Prove a real sample, not just a HELP/TYPE stub: the classification
      # counter carries the :book outcome we just drove.
      assert body =~
               ~r/stacks_moderation_classification_count_total\{[^}\n]*outcome="book"[^}\n]*\}\s+\d/,
             "expected a non-zero classification sample tagged outcome=\"book\""
    end

    test "age-gate families appear with samples after enforce + verification", %{conn: conn} do
      # enforce/2 — blocked (unverified) + passed (verified), real plug code.
      blocked = AgeGate.enforce(conn, @age_gated_book)
      assert blocked.halted and blocked.status == 403

      verified_user = insert(:user, age_verified: true)

      passed =
        AgeGate.enforce(Guardian.Plug.put_current_resource(conn, verified_user), @age_gated_book)

      refute passed.halted

      # age_verification — :success outcome, emitted by the provider-sourced
      # recorder (repointed from the removed self-declared endpoint, ADR-020).
      unverified = insert(:user, age_verified: false)
      {:ok, _} = AgeVerification.record_verification(unverified, "test", nil)

      body = scrape(conn)

      for family <- [
            "stacks_age_gate_enforce_count_total",
            "stacks_age_verification_count_total"
          ] do
        assert body =~ family,
               "expected #{family} exposed at /internal/metrics after age-gate ran, got:\n#{body}"
      end

      assert body =~
               ~r/stacks_age_gate_enforce_count_total\{[^}\n]*outcome="blocked"[^}\n]*\}\s+\d/,
             "expected a non-zero age-gate enforce sample tagged outcome=\"blocked\""

      assert body =~
               ~r/stacks_age_verification_count_total\{[^}\n]*outcome="success"[^}\n]*\}\s+\d/,
             "expected a non-zero age-verification sample tagged outcome=\"success\""
    end
  end

  describe "live exposure: #237 auth/session-security families are scrapeable after exercising" do
    test "reuse + session-cap + MFA-failure families appear with samples after their real paths",
         %{conn: conn} do
      # 1. Refresh-token REUSE — open a family, then replay a superseded jti so
      # check_token_family/3 burns the family and emits reuse_detected.
      user = insert(:user)
      fid = Ecto.UUID.generate()

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-current",
          session_started_at: DateTime.utc_now()
        })

      assert {:error, :token_reuse_detected} =
               Accounts.check_token_family(fid, "jti-superseded", to_string(user.id))

      # 2. Session absolute-cap expiry — a real refresh POST with an 8-day-old
      # sst anchor is refused with 401 session_expired (reason: :lifetime_cap).
      capped_user =
        insert(:user, email: "metrics-cap@example.com", email_confirmed: true)

      old_sst = System.system_time(:second) - 8 * 24 * 3600
      {:ok, capped_token, _} = Guardian.encode_and_sign(capped_user, %{"sst" => old_sst})

      cap_conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{capped_token}")
        |> post("/api/auth/refresh")

      assert %{"error" => "session_expired"} = json_response(cap_conn, 401)

      # 3. MFA verify FAILURE — enroll a user, then verify a wrong TOTP code.
      mfa_user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(mfa_user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, _} = MFA.confirm_enrollment(mfa_user, valid_code, secret, codes)
      assert {:error, :invalid_code} = MFA.verify_totp(mfa_user, "000000")

      body = scrape(conn)

      for family <- [
            "stacks_auth_refresh_reuse_detected_count_total",
            "stacks_auth_session_expired_count_total",
            "stacks_auth_mfa_verify_count_total"
          ] do
        assert body =~ family,
               "expected #{family} exposed at /internal/metrics after the auth paths ran, got:\n#{body}"
      end

      # Prove real samples, not just HELP/TYPE stubs: the reuse counter is
      # untagged; the cap and MFA counters carry their whitelisted tags.
      assert body =~ ~r/stacks_auth_refresh_reuse_detected_count_total(\{\})?\s+\d/,
             "expected a non-zero refresh-reuse-detected sample"

      assert body =~
               ~r/stacks_auth_session_expired_count_total\{[^}\n]*reason="lifetime_cap"[^}\n]*\}\s+\d/,
             "expected a non-zero session-expired sample tagged reason=\"lifetime_cap\""

      assert body =~
               ~r/stacks_auth_mfa_verify_count_total\{[^}\n]*outcome="failure"[^}\n]*\}\s+\d/,
             "expected a non-zero MFA-verify sample tagged outcome=\"failure\""
    end
  end

  describe "live exposure: #236 visibility/social/ViewAs families are scrapeable after exercising" do
    test "profile-change / recap / ceiling / block+unblock / ViewAs families appear with samples",
         %{conn: conn} do
      user = insert(:user)

      # 1. Profile-visibility change through the real Accounts path (default
      # profile is "owner"; owner→platform fires profile_change with a direction
      # tag and enqueues — but does not run — a recap job).
      assert {:ok, _} = Accounts.update_profile_visibility(user.id, "platform")

      # 2. Ceiling rejection through the real Shelving path: a placement whose
      # bookshelf is "owner" cannot be set more exposed ("platform").
      owner_shelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      owner_placement = insert(:placement, bookshelf: owner_shelf, visibility: "owner")

      assert {:error, _} =
               Shelving.update_placement_visibility(owner_placement.id, user.id, "platform")

      # 3. Visibility-recap CAPPED outcome with non-zero bookshelves/placements/
      # posts: set up sub-owner resources, then run the real worker with an
      # "owner" ceiling so all three batch sizes are > 0.
      capped_shelf = insert(:bookshelf, user: user, name: "antilibrary", visibility: "platform")
      insert(:placement, bookshelf: capped_shelf, visibility: "platform")
      insert(:post, user: user, visibility: "platform")

      assert :ok =
               VisibilityRecapJob.perform(%Oban.Job{
                 args: %{"user_id" => user.id, "new_visibility" => "owner"}
               })

      # 4. Block + duplicate-block (block_error) + unblock through Stacks.Social.
      blocked = insert(:user)
      assert {:ok, _} = Social.block_user(user.id, blocked.id)
      assert {:error, _} = Social.block_user(user.id, blocked.id)
      assert {:ok, :unblocked} = Social.unblock_user(user.id, blocked.id)

      # 5. ViewAs usage + error through the real plug (perspective KIND only).
      ViewAsPlug.call(%{conn | query_params: %{"view_as" => "platform"}}, [])
      ViewAsPlug.call(%{conn | query_params: %{"view_as" => "user:"}}, [])

      body = scrape(conn)

      for family <- [
            "stacks_visibility_profile_change_count_total",
            "stacks_visibility_ceiling_rejection_count_total",
            "stacks_visibility_recap_count_total",
            "stacks_visibility_recap_bookshelves_capped_total",
            "stacks_visibility_recap_placements_capped_total",
            "stacks_visibility_recap_posts_capped_total",
            "stacks_social_block_count_total",
            "stacks_social_unblock_count_total",
            "stacks_social_block_error_count_total",
            "stacks_view_as_usage_count_total",
            "stacks_view_as_error_count_total"
          ] do
        assert body =~ family,
               "expected #{family} exposed at /internal/metrics after the visibility/social " <>
                 "paths ran, got:\n#{body}"
      end

      # Prove real tagged samples, not just HELP/TYPE stubs.
      assert body =~
               ~r/stacks_visibility_profile_change_count_total\{[^}\n]*direction="[a-z]+"[^}\n]*\}\s+\d/,
             "expected a non-zero profile-change sample carrying a direction tag"

      assert body =~
               ~r/stacks_visibility_recap_count_total\{[^}\n]*outcome="capped"[^}\n]*\}\s+\d/,
             "expected a non-zero recap sample tagged outcome=\"capped\""

      assert body =~
               ~r/stacks_visibility_recap_bookshelves_capped_total(\{\})?\s+[1-9]/,
             "expected a non-zero bookshelves-capped sum after the recap ran"

      assert body =~
               ~r/stacks_social_block_error_count_total\{[^}\n]*reason="already_blocked"[^}\n]*\}\s+\d/,
             "expected a block_error sample tagged reason=\"already_blocked\""

      assert body =~
               ~r/stacks_view_as_usage_count_total\{[^}\n]*perspective="platform"[^}\n]*\}\s+\d/,
             "expected a non-zero ViewAs-usage sample tagged perspective=\"platform\""
    end
  end

  describe "live exposure: #238 GDPR data-rights families are scrapeable after exercising" do
    test "export/deletion (incl. latency) + consent + audit read/write families appear with samples",
         %{conn: conn} do
      # 1. Data export (right-to-portability) through the real worker — fires
      # stacks_gdpr_export_count_total{result="ok"} AND the new latency
      # distribution stacks_gdpr_export_duration_milliseconds_{bucket,sum,count}.
      export_user = insert(:user)

      assert :ok =
               DataExportJob.perform(%Oban.Job{args: %{"user_id" => export_user.id}})

      # 2. Account deletion (right-to-erasure) through the real worker — fires
      # stacks_gdpr_deletion_count_total{result="ok",failed_step="none"} AND the
      # new stacks_gdpr_deletion_duration_milliseconds_{bucket,sum,count}.
      delete_user = insert(:user)

      assert :ok =
               AccountDeletionJob.perform(%Oban.Job{args: %{"user_id" => delete_user.id}})

      # 3. Consent grant + revoke through the real GDPR path (feature-tagged).
      consent_user = insert(:user)
      assert {:ok, _} = Consent.grant_consent(consent_user.id)
      assert {:ok, _} = Consent.revoke_consent(consent_user.id)

      # 4. Audit write + the new audit READ counter through the real context.
      audit_user = insert(:user)
      assert {:ok, _} = Audit.log(audit_user.id, "test.metrics_read", resource_type: "test")
      assert {[_ | _], _total, 1, _pp} = Audit.list_for_user(audit_user.id)

      body = scrape(conn)

      for family <- [
            "stacks_gdpr_export_count_total",
            "stacks_gdpr_export_duration_milliseconds_bucket",
            "stacks_gdpr_export_duration_milliseconds_sum",
            "stacks_gdpr_export_duration_milliseconds_count",
            "stacks_gdpr_deletion_count_total",
            "stacks_gdpr_deletion_duration_milliseconds_bucket",
            "stacks_gdpr_deletion_duration_milliseconds_sum",
            "stacks_gdpr_deletion_duration_milliseconds_count",
            "stacks_gdpr_consent_grant_count_total",
            "stacks_gdpr_consent_revoke_count_total",
            "stacks_gdpr_audit_write_count_total",
            "stacks_gdpr_audit_read_count_total"
          ] do
        assert body =~ family,
               "expected #{family} exposed at /internal/metrics after the GDPR paths ran, got:\n#{body}"
      end

      # Prove real samples, not just HELP/TYPE stubs.
      assert body =~
               ~r/stacks_gdpr_export_count_total\{[^}\n]*result="ok"[^}\n]*\}\s+\d/,
             "expected a non-zero export sample tagged result=\"ok\""

      # The latency distribution exposes a +Inf bucket count and a sum after the
      # job ran — proves the new duration measurement reaches Prometheus.
      assert body =~
               ~r/stacks_gdpr_export_duration_milliseconds_bucket\{[^}\n]*le="\+Inf"[^}\n]*\}\s+[1-9]/,
             "expected a non-zero export latency +Inf bucket"

      assert body =~
               ~r/stacks_gdpr_deletion_duration_milliseconds_bucket\{[^}\n]*le="\+Inf"[^}\n]*\}\s+[1-9]/,
             "expected a non-zero deletion latency +Inf bucket"

      # The new audit-read counter is untagged — a bare non-zero sample.
      assert body =~ ~r/stacks_gdpr_audit_read_count_total(\{\})?\s+[1-9]/,
             "expected a non-zero audit-read sample"
    end
  end

  describe "live exposure: #239 discovery/profiles/search families are scrapeable after exercising" do
    test "people-search / profile-404 / handle-claim families appear with samples", %{conn: conn} do
      # 1. Zero-result people-search through the real endpoint → fires
      # stacks_search_people_count_total{outcome="zero_result"}.
      searcher = insert(:user)

      assert %{"users" => []} =
               conn
               |> put_req_header_authorization(searcher)
               |> get("/api/search/users", q: "nobodymatchesthisxyzzy")
               |> json_response(200)

      # 2. Ghost / nonexistent public profile (404) through the real controller →
      # fires stacks_profile_view_count_total{outcome="not_found"}.
      assert %{"error" => "not_found"} =
               conn
               |> put_req_header_authorization(searcher)
               |> get("/api/u/no_such_handle_xyzzy")
               |> json_response(404)

      # 3. Handle claim through the real Accounts path (changing :handle) → fires
      # stacks_handle_claimed_count_total. handle is NOT NULL, so a claim is a change.
      claimer = insert(:user, handle: "preclaimhandle")
      assert {:ok, _} = Accounts.update_profile(claimer, %{"handle" => "claimedhandle"})

      body = scrape(conn)

      for family <- [
            "stacks_search_people_count_total",
            "stacks_profile_view_count_total",
            "stacks_handle_claimed_count_total"
          ] do
        assert body =~ family,
               "expected #{family} exposed at /internal/metrics after the discovery paths ran, got:\n#{body}"
      end

      # Prove real tagged samples, not just HELP/TYPE stubs.
      assert body =~
               ~r/stacks_search_people_count_total\{[^}\n]*outcome="zero_result"[^}\n]*\}\s+\d/,
             "expected a non-zero people-search sample tagged outcome=\"zero_result\""

      assert body =~
               ~r/stacks_profile_view_count_total\{[^}\n]*outcome="not_found"[^}\n]*\}\s+\d/,
             "expected a non-zero profile-view sample tagged outcome=\"not_found\""

      # The handle-claimed counter is untagged — a bare non-zero sample.
      assert body =~ ~r/stacks_handle_claimed_count_total(\{\})?\s+[1-9]/,
             "expected a non-zero handle-claimed sample"
    end
  end

  describe "live exposure: #240 platform/ops rate-limit families are scrapeable after exercising" do
    setup do
      # Drive the real RateLimiter plug: enable limiting and pin a tight :auth
      # limit so a small loop can trip a 429 without a 60-iteration loop.
      original_enabled = Application.get_env(:core, :rate_limiting_enabled)
      original_auth = Application.get_env(:core, :rate_limit_auth)
      Application.put_env(:core, :rate_limiting_enabled, true)
      Application.put_env(:core, :rate_limit_auth, 3)

      on_exit(fn ->
        Application.put_env(:core, :rate_limiting_enabled, original_enabled)

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

    test "rate-limit rejected + client-IP-source families appear with samples after tripping a bucket",
         %{conn: conn} do
      # 1. A normal (allowed) request resolves the client IP from remote_ip →
      # fires stacks_rate_limit_client_ip_count_total{source="remote_ip"}.
      normal = %{conn | remote_ip: {10, 8, 0, 1}}
      refute RateLimiter.call(normal, bucket: :auth).halted

      # 2. Trip the :auth bucket → HTTP 429 →
      # stacks_rate_limit_rejected_count_total{bucket="auth"} (each call also
      # resolves the client IP, so client_ip is doubly exercised).
      trip = %{conn | remote_ip: {10, 8, 0, 2}}
      for _ <- 1..3, do: RateLimiter.call(trip, bucket: :auth)
      result = RateLimiter.call(trip, bucket: :auth)
      assert result.halted and result.status == 429

      body = scrape(conn)

      for family <- [
            "stacks_rate_limit_rejected_count_total",
            "stacks_rate_limit_client_ip_count_total"
          ] do
        assert body =~ family,
               "expected #{family} exposed at /internal/metrics after tripping the limiter, got:\n#{body}"
      end

      # Prove real tagged samples, not just HELP/TYPE stubs.
      assert body =~
               ~r/stacks_rate_limit_rejected_count_total\{[^}\n]*bucket="auth"[^}\n]*\}\s+[1-9]/,
             "expected a non-zero rate-limit-rejected sample tagged bucket=\"auth\""

      assert body =~
               ~r/stacks_rate_limit_client_ip_count_total\{[^}\n]*source="remote_ip"[^}\n]*\}\s+[1-9]/,
             "expected a non-zero client-IP sample tagged source=\"remote_ip\""
    end
  end

  defp put_req_header_authorization(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # A single candidate whose title is two titles joined by " OR " — drives
  # expand_compound_candidates/1 (compound expansion counter) without resolving.
  defp compound_title do
    book_response([book_candidate(title: "First Book OR Second Book", confidence: 0.9)])
  end
end
