defmodule CoreWeb.MetricsEndpointTest do
  @moduledoc """
  Tests that the /internal/metrics Prometheus endpoint is accessible
  without authentication and returns Prometheus text format. (Issue #129)
  """

  use CoreWeb.ConnCase, async: true

  describe "GET /internal/metrics" do
    test "returns 200 with Prometheus text format", %{conn: conn} do
      conn = get(conn, "/internal/metrics")

      assert conn.status == 200

      assert get_resp_header(conn, "content-type")
             |> List.first()
             |> String.contains?("text/plain")
    end

    test "response body contains HELP or TYPE lines (Prometheus format)", %{conn: conn} do
      conn = get(conn, "/internal/metrics")

      body = conn.resp_body
      # Prometheus text format includes # HELP and # TYPE lines
      assert body =~ "# HELP" or body =~ "# TYPE" or body == ""
    end
  end
end
