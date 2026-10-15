defmodule StacksWeb.InternalControllerTest do
  use CoreWeb.ConnCase, async: true

  describe "POST /api/internal/smoke/circuit_breakers" do
    test "returns 404 when smoke_tests_enabled is false (production default)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/smoke/circuit_breakers", %{})

      assert json_response(conn, 404)
    end

    test "returns 401 when smoke_tests_enabled is true but token is absent", %{conn: conn} do
      original = Application.get_env(:core, :smoke_tests_enabled)
      Application.put_env(:core, :smoke_tests_enabled, true)

      on_exit(fn -> Application.put_env(:core, :smoke_tests_enabled, original) end)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/smoke/circuit_breakers", %{})

      assert json_response(conn, 401)
    end

    test "returns 401 when smoke_tests_enabled is true but token is tampered", %{conn: conn} do
      original = Application.get_env(:core, :smoke_tests_enabled)
      Application.put_env(:core, :smoke_tests_enabled, true)

      on_exit(fn -> Application.put_env(:core, :smoke_tests_enabled, original) end)

      conn =
        conn
        |> put_req_header("x-internal-token", "1234567890.deadbeefdeadbeef")
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/smoke/circuit_breakers", %{})

      assert json_response(conn, 401)
    end
  end
end
