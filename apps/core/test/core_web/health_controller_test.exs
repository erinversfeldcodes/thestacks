defmodule CoreWeb.HealthControllerTest do
  use CoreWeb.ConnCase, async: false

  describe "GET /api/health (liveness)" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, "/api/health")
      assert %{"status" => "ok", "service" => "core"} = json_response(conn, 200)
    end
  end

  describe "GET /api/health/ready (readiness)" do
    setup do
      on_exit(fn -> Application.delete_env(:core, :readiness_check) end)
      :ok
    end

    test "returns 200 with db true when the database answers", %{conn: conn} do
      conn = get(conn, "/api/health/ready")
      assert %{"status" => "ok", "db" => true} = json_response(conn, 200)
    end

    test "the default check really queries the database" do
      assert CoreWeb.HealthController.db_ready() == :ok
      # the circuit-breaker probe shares the same SELECT 1 path
      assert Stacks.CircuitBreakers.probe_neon() == :ok
    end

    test "returns 503 degraded when the database is unreachable", %{conn: conn} do
      Application.put_env(:core, :readiness_check, fn -> {:error, :connection_refused} end)

      conn = get(conn, "/api/health/ready")
      assert %{"status" => "degraded", "db" => false} = json_response(conn, 503)
    end
  end
end
