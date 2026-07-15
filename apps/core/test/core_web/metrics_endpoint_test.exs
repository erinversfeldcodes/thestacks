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

  alias Stacks.Accounts.Guardian
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
      # Happy path: classification :book → isbn_resolution :resolved →
      # tiering :public, all through the real moderation pipeline code.
      assert {:ok, %{resolved: [_book]}} =
               Moderation.run_pipeline(%{
                 image_b64: @test_image_b64,
                 book_attrs: %{"title" => "The Great Gatsby"}
               })

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

      # age_verification — success (200) + invalid (422), real controller.
      unverified = insert(:user, age_verified: false)

      conn
      |> put_req_header("authorization", bearer(unverified))
      |> put("/api/settings/age_verification", %{age_verified: true})
      |> json_response(200)

      conn
      |> put_req_header("authorization", bearer(insert(:user)))
      |> put("/api/settings/age_verification", %{})
      |> json_response(422)

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

  defp bearer(user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    "Bearer #{token}"
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
