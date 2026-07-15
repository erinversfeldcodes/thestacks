defmodule StacksWeb.Plugs.MetricsAuthTest do
  @moduledoc """
  Tests for the /internal/metrics auth plug (Issue #136 Phase 1, DoD #4).

  Public requests to /internal/metrics are rejected with 401 unless the
  request carries `authorization: Bearer <METRICS_SCRAPE_TOKEN>` matching the
  configured token.

  The one exception (Issue #232) is Fly's managed-Prometheus scrape, which
  hits the machine directly over 6PN and cannot present the bearer. That
  path is allowed WITHOUT a token — but only when it is provably internal:
  a `fdaa::/16` remote_ip AND the absence of the `fly-client-ip` header that
  fly-proxy stamps on every public-edge request. A bare 6PN remote_ip is NOT
  enough on its own (public HTTPS re-originates over 6PN too), so we assert
  that a 6PN request *with* `fly-client-ip` (a proxied public caller) still
  gets 401. See the plug's `@moduledoc` for the full rationale.

  We exercise the plug in two ways:

    1. Unit: call `MetricsAuth.call/2` directly with synthesised conns and
       verify the plug halts (401) or passes through.
    2. Integration: GET /internal/metrics via the endpoint and check the
       status code — 200 for authorised callers, 401 for unauthorised.
  """

  # async: false — we mutate Application env for the configured token and
  # the endpoint is a shared process.
  use CoreWeb.ConnCase, async: false

  alias StacksWeb.Plugs.MetricsAuth

  @valid_token "test-metrics-scrape-token-for-issue-136"

  @public_ipv4 {203, 0, 113, 7}
  # A representative Fly 6PN address in the fdaa::/16 block that the old
  # allowlist would have matched. Kept so we can assert the plug does NOT
  # treat it as authorized without a bearer.
  @fly_6pn_ip {0xFDAA, 0, 0, 0, 0, 0, 0, 0x1}

  setup do
    original = Application.get_env(:core, :metrics_scrape_token)
    Application.put_env(:core, :metrics_scrape_token, @valid_token)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:core, :metrics_scrape_token)
      else
        Application.put_env(:core, :metrics_scrape_token, original)
      end
    end)

    :ok
  end

  defp call_plug(conn) do
    MetricsAuth.call(conn, MetricsAuth.init([]))
  end

  defp base_conn do
    Phoenix.ConnTest.build_conn(:get, "/internal/metrics")
  end

  # ---------------------------------------------------------------------------
  # Unit tests — the plug itself
  # ---------------------------------------------------------------------------

  describe "MetricsAuth.call/2 — Fly managed-Prometheus 6PN bypass (Issue #232)" do
    test "allows a direct 6PN scrape of /internal/metrics with NO bearer token" do
      # Fly's managed Prometheus scrapes the machine directly over 6PN: a
      # fdaa::/16 remote_ip AND no fly-proxy `fly-client-ip` header. This is
      # the one path allowed without the bearer.
      result =
        base_conn()
        |> Map.put(:remote_ip, @fly_6pn_ip)
        |> call_plug()

      refute result.halted,
             "expected a direct 6PN metrics scrape (no fly-client-ip) to be allowed without a token"
    end

    test "still 401s a 6PN request that carries a fly-client-ip header (proxied public caller)" do
      # Public HTTPS terminates at fly-proxy and re-originates over 6PN, so
      # remote_ip is fdaa::/16 for public callers too — but fly-proxy stamps
      # an unspoofable `fly-client-ip`. Its presence proves the request came
      # via the public edge, so the bearer is still required.
      result =
        base_conn()
        |> Map.put(:remote_ip, @fly_6pn_ip)
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> call_plug()

      assert result.halted, "a proxied public caller (fly-client-ip present) must not be bypassed"
      assert result.status == 401
    end

    test "does NOT bypass a non-metrics /internal/* path even from a bare 6PN source" do
      # The bypass is scoped to /internal/metrics only; /internal/deps-check
      # (and any other internal route) still demands the bearer.
      result =
        Phoenix.ConnTest.build_conn(:get, "/internal/deps-check")
        |> Map.put(:remote_ip, @fly_6pn_ip)
        |> call_plug()

      assert result.halted, "the bypass must not extend beyond /internal/metrics"
      assert result.status == 401
    end

    test "does NOT bypass a public-IP source even without a fly-client-ip header" do
      # Defence in depth: remote_ip must be inside fdaa::/16 for the bypass.
      # A public source with no fly-client-ip (e.g. a misrouted direct hit)
      # is still rejected.
      result =
        base_conn()
        |> Map.put(:remote_ip, @public_ipv4)
        |> call_plug()

      assert result.halted
      assert result.status == 401
    end
  end

  describe "MetricsAuth.call/2 — bearer token" do
    test "passes a request carrying the configured Bearer token" do
      result =
        base_conn()
        |> Map.put(:remote_ip, @public_ipv4)
        |> put_req_header("authorization", "Bearer #{@valid_token}")
        |> call_plug()

      refute result.halted,
             "expected valid Bearer token to pass through, got halted=#{result.halted}"
    end

    test "rejects a request carrying an invalid Bearer token with 401" do
      result =
        base_conn()
        |> Map.put(:remote_ip, @public_ipv4)
        |> put_req_header("authorization", "Bearer some-wrong-token")
        |> call_plug()

      assert result.halted
      assert result.status == 401
    end
  end

  describe "MetricsAuth.call/2 — no credentials from public network" do
    test "rejects a public-IP request with no auth with 401" do
      result =
        base_conn()
        |> Map.put(:remote_ip, @public_ipv4)
        |> call_plug()

      assert result.halted
      assert result.status == 401
    end

    test "rejects a request with malformed authorization header with 401" do
      result =
        base_conn()
        |> Map.put(:remote_ip, @public_ipv4)
        |> put_req_header("authorization", "NotBearer something")
        |> call_plug()

      assert result.halted
      assert result.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # Integration — GET /internal/metrics through the endpoint
  # ---------------------------------------------------------------------------

  describe "GET /internal/metrics (integration)" do
    test "200 when the request carries the configured Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@valid_token}")
        |> get("/internal/metrics")

      assert conn.status == 200
    end

    test "401 when the request carries an invalid Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer garbage")
        |> get("/internal/metrics")

      assert conn.status == 401
    end

    test "401 when a public-IP request carries no authorization", %{conn: conn} do
      # Phoenix.ConnTest.build_conn/0 uses 127.0.0.1 by default which is NOT a
      # 6PN address, so the plug should reject without a bearer.
      conn = get(conn, "/internal/metrics")

      assert conn.status == 401
    end
  end
end
