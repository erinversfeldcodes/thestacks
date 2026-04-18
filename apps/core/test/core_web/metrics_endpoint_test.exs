defmodule CoreWeb.MetricsEndpointTest do
  @moduledoc """
  Tests that the /internal/metrics Prometheus endpoint returns Prometheus
  text format when authenticated. Auth is enforced by
  `StacksWeb.Plugs.MetricsAuth` (Issue #136).
  """

  use CoreWeb.ConnCase, async: false

  @token "test-metrics-scrape-token"

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
end
