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

  describe "MetricsAuth.call/2 — no IP-based bypass (former 6PN bypass removed, #393)" do
    test "a bearer-less 6PN scrape of /internal/metrics is now 401" do
      # The Fly managed-Prometheus 6PN bypass (Issue #232) was removed in #393:
      # post-ADR-021 nothing scrapes this route (metrics are pushed to VM), so a
      # request that used to be waved through — fdaa::/16 remote_ip, no
      # fly-client-ip, no bearer — must now be rejected like any other. This is
      # the inverted assertion: the DoD is that the dead bypass is gone.
      result =
        base_conn()
        |> Map.put(:remote_ip, @fly_6pn_ip)
        |> call_plug()

      assert result.halted, "a bearer-less 6PN scrape must no longer be bypassed"
      assert result.status == 401
    end

    test "a 6PN request carrying a fly-client-ip header is 401 without a bearer" do
      result =
        base_conn()
        |> Map.put(:remote_ip, @fly_6pn_ip)
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> call_plug()

      assert result.halted
      assert result.status == 401
    end

    test "a non-metrics /internal/* path from a 6PN source is 401 without a bearer" do
      result =
        Phoenix.ConnTest.build_conn(:get, "/internal/deps-check")
        |> Map.put(:remote_ip, @fly_6pn_ip)
        |> call_plug()

      assert result.halted
      assert result.status == 401
    end

    test "a public-IP source without a fly-client-ip header is 401 without a bearer" do
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
