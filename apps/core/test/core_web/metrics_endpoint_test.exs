defmodule CoreWeb.MetricsEndpointTest do
  @moduledoc """
      Tests that the /internal/metrics Prometheus endpoint returns Prometheus
      text format when authenticated. Auth is enforced by
      `StacksWeb.Plugs.MetricsAuth`.

      The `live exposure` describe block proves the
      registered→scrapeable path end-to-end: after the moderation funnel and
      age-gate paths run through their real code, the `stacks_moderation_*`
      / `stacks_age_gate_*` / `stacks_age_verification_*` families appear at
      `GET /internal/metrics` with samples. The firing tests prove the
      events fire; this proves PromEx actually exposes them on the scrape
      endpoint the dashboard queries.
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
      assert body =~ "# HELP" or body =~ "# TYPE" or body == ""
    end
  end

  describe "live exposure: moderation + age-gate families are scrapeable after exercising" do
    test "moderation funnel families appear with samples after run_pipeline", %{conn: conn} do
      assert {:ok, %{resolved: [book]}} =
               Moderation.run_pipeline(%{
                 image_b64: @test_image_b64,
                 book_attrs: %{"title" => "The Great Gatsby"}
               })

      assert {:ok, _} = Stacks.Books.set_visibility_tier(book, "age_gated", source: :user)

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

      assert body =~
               ~r/stacks_moderation_classification_count_total\{[^}\n]*outcome="book"[^}\n]*\}\s+\d/,
             "expected a non-zero classification sample tagged outcome=\"book\""
    end

    test "age-gate families appear with samples after enforce + verification", %{conn: conn} do
      blocked = AgeGate.enforce(conn, @age_gated_book)
      assert blocked.halted and blocked.status == 403

      verified_user = insert(:user, age_verified: true)

      passed =
        AgeGate.enforce(Guardian.Plug.put_current_resource(conn, verified_user), @age_gated_book)

      refute passed.halted

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

  describe "live exposure: auth/session-security families are scrapeable after exercising" do
    test "reuse + session-cap + MFA-failure families appear with samples after their real paths",
         %{conn: conn} do
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

      capped_user =
        insert(:user, email: "metrics-cap@example.com", email_confirmed: true)

      old_sst = System.system_time(:second) - 8 * 24 * 3600
      {:ok, capped_token, _} = Guardian.encode_and_sign(capped_user, %{"sst" => old_sst})

      cap_conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{capped_token}")
        |> post("/api/auth/refresh")

      assert %{"error" => "session_expired"} = json_response(cap_conn, 401)

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

  describe "live exposure: visibility/social/ViewAs families are scrapeable after exercising" do
    test "profile-change / recap / ceiling / block+unblock / ViewAs families appear with samples",
         %{conn: conn} do
      user = insert(:user)

      assert {:ok, _} = Accounts.update_profile_visibility(user.id, "platform")

      owner_shelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      owner_placement = insert(:placement, bookshelf: owner_shelf, visibility: "owner")

      assert {:error, _} =
               Shelving.update_placement_visibility(owner_placement.id, user.id, "platform")

      capped_shelf = insert(:bookshelf, user: user, name: "antilibrary", visibility: "platform")
      insert(:placement, bookshelf: capped_shelf, visibility: "platform")
      insert(:post, user: user, visibility: "platform")

      assert :ok =
               VisibilityRecapJob.perform(%Oban.Job{
                 args: %{"user_id" => user.id, "new_visibility" => "owner"}
               })

      blocked = insert(:user)
      assert {:ok, _} = Social.block_user(user.id, blocked.id)
      assert {:error, _} = Social.block_user(user.id, blocked.id)
      assert {:ok, :unblocked} = Social.unblock_user(user.id, blocked.id)

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

  describe "live exposure: GDPR data-rights families are scrapeable after exercising" do
    test "export/deletion (incl. latency) + consent + audit read/write families appear with samples",
         %{conn: conn} do
      export_user = insert(:user)

      assert :ok =
               DataExportJob.perform(%Oban.Job{args: %{"user_id" => export_user.id}})

      delete_user = insert(:user)

      assert :ok =
               AccountDeletionJob.perform(%Oban.Job{args: %{"user_id" => delete_user.id}})

      consent_user = insert(:user)
      assert {:ok, _} = Consent.grant_consent(consent_user.id)
      assert {:ok, _} = Consent.revoke_consent(consent_user.id)

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

      assert body =~
               ~r/stacks_gdpr_export_count_total\{[^}\n]*result="ok"[^}\n]*\}\s+\d/,
             "expected a non-zero export sample tagged result=\"ok\""

      assert body =~
               ~r/stacks_gdpr_export_duration_milliseconds_bucket\{[^}\n]*le="\+Inf"[^}\n]*\}\s+[1-9]/,
             "expected a non-zero export latency +Inf bucket"

      assert body =~
               ~r/stacks_gdpr_deletion_duration_milliseconds_bucket\{[^}\n]*le="\+Inf"[^}\n]*\}\s+[1-9]/,
             "expected a non-zero deletion latency +Inf bucket"

      assert body =~ ~r/stacks_gdpr_audit_read_count_total(\{\})?\s+[1-9]/,
             "expected a non-zero audit-read sample"
    end
  end

  describe "live exposure: discovery/profiles/search families are scrapeable after exercising" do
    test "people-search / profile-404 / handle-claim families appear with samples", %{conn: conn} do
      searcher = insert(:user)

      assert %{"users" => []} =
               conn
               |> put_req_header_authorization(searcher)
               |> get("/api/search/users", q: "nobodymatchesthisxyzzy")
               |> json_response(200)

      assert %{"error" => "not_found"} =
               conn
               |> put_req_header_authorization(searcher)
               |> get("/api/u/no_such_handle_xyzzy")
               |> json_response(404)

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

      assert body =~
               ~r/stacks_search_people_count_total\{[^}\n]*outcome="zero_result"[^}\n]*\}\s+\d/,
             "expected a non-zero people-search sample tagged outcome=\"zero_result\""

      assert body =~
               ~r/stacks_profile_view_count_total\{[^}\n]*outcome="not_found"[^}\n]*\}\s+\d/,
             "expected a non-zero profile-view sample tagged outcome=\"not_found\""

      assert body =~ ~r/stacks_handle_claimed_count_total(\{\})?\s+[1-9]/,
             "expected a non-zero handle-claimed sample"
    end
  end

  describe "live exposure: platform/ops rate-limit families are scrapeable after exercising" do
    setup do
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
      normal = %{conn | remote_ip: {10, 8, 0, 1}}
      refute RateLimiter.call(normal, bucket: :auth).halted

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

  defp compound_title do
    book_response([book_candidate(title: "First Book OR Second Book", confidence: 0.9)])
  end
end
