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

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.AgeVerification
  alias Stacks.MFA
  alias Stacks.Moderation
  alias StacksWeb.Plugs.AgeGate

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
      original = Application.get_env(:core, :vision_client)
      Application.put_env(:core, :vision_client, __MODULE__.CompoundTitleClient)

      try do
        assert {:error, :isbn_not_found} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})
      after
        Application.put_env(:core, :vision_client, original)
      end

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
        Accounts.open_token_family(%{
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

  # Vision client returning a single candidate whose title is two titles
  # joined by " OR " — drives expand_compound_candidates/1 (compound
  # expansion counter) without resolving.
  defmodule CompoundTitleClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.9,
           "books" => [
             %{
               "title" => "First Book OR Second Book",
               "author" => nil,
               "potential_isbns" => [],
               "raw_text" => nil,
               "confidence" => 0.9
             }
           ],
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end
end
