defmodule CoreWeb.HealthControllerTest do
  use CoreWeb.ConnCase, async: true

  describe "GET /api/health" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, "/api/health")
      assert %{"status" => "ok", "service" => "core"} = json_response(conn, 200)
    end
  end
end
