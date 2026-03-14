defmodule StacksWeb.CostControllerTest do
  @moduledoc "Tests for the public cost transparency endpoint."

  use CoreWeb.ConnCase, async: true

  describe "GET /api/costs" do
    test "returns 200 with cost breakdown — no auth required", %{conn: conn} do
      conn = get(conn, "/api/costs")
      response = json_response(conn, 200)

      assert %{"data" => data} = response
      assert is_list(data["line_items"])
      assert is_integer(data["total_cents"])
      assert data["currency"] == "USD"
      assert is_number(data["cost_per_book"])
      assert is_integer(data["book_count"])
      assert is_list(data["monthly_totals"])
      assert is_binary(data["generated_at"])
    end

    test "does not expose any user data", %{conn: conn} do
      conn = get(conn, "/api/costs")
      response = json_response(conn, 200)
      body = Jason.encode!(response)

      refute String.contains?(body, "user_id")
      refute String.contains?(body, "email")
      refute String.contains?(body, "password")
    end
  end
end
