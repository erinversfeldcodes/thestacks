defmodule StacksWeb.Plugs.MetricsAuthTest do
  @moduledoc """
      `/internal/*` auth plug tests: 401 without the matching
      `Bearer <METRICS_SCRAPE_TOKEN>`. The one exception is Fly's
      managed-Prometheus scrape over 6PN, allowed WITHOUT a token only when
      provably internal: `fdaa::/16` remote_ip AND no `fly-client-ip` header
      (which the edge always adds to public traffic) — both conditions
      asserted, including the spoof case.
  """

  use CoreWeb.ConnCase, async: false

  alias StacksWeb.Plugs.MetricsAuth

  @valid_token "test-metrics-scrape-token-for-issue-136"

  @public_ipv4 {203, 0, 113, 7}
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

  describe "MetricsAuth.call/2 — no IP-based bypass (former 6PN bypass removed, )" do
    test "a bearer-less 6PN scrape of /internal/metrics is now 401" do
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
      conn = get(conn, "/internal/metrics")

      assert conn.status == 401
    end
  end
end
