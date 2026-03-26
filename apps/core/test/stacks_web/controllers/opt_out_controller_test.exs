defmodule StacksWeb.OptOutControllerTest do
  @moduledoc "Tests for the unauthenticated opt-out endpoint."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  describe "POST /api/opt-out" do
    test "successfully opts out a discovered source", %{conn: conn} do
      insert(:discovered_source, url: "https://mybookshop.com", status: "pending_review")

      conn =
        post(conn, "/api/opt-out", %{
          url: "https://mybookshop.com",
          email: "owner@mybookshop.com"
        })

      assert %{"message" => "Source has been opted out successfully."} = json_response(conn, 200)

      # Verify the source was actually excluded
      source = Stacks.Discovery.get_source_by_url("https://mybookshop.com")
      assert source.status == "excluded"
      assert source.exclusion_email == "owner@mybookshop.com"
      assert source.excluded_at != nil
    end

    test "returns 404 when URL does not match any source", %{conn: conn} do
      conn =
        post(conn, "/api/opt-out", %{
          url: "https://unknown-shop.com",
          email: "owner@unknown.com"
        })

      assert %{"error" => _} = json_response(conn, 404)
    end

    test "returns 422 for invalid email format", %{conn: conn} do
      insert(:discovered_source, url: "https://bademail-shop.com")

      conn =
        post(conn, "/api/opt-out", %{
          url: "https://bademail-shop.com",
          email: "not-an-email"
        })

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 422 when required params are missing", %{conn: conn} do
      conn = post(conn, "/api/opt-out", %{})
      assert %{"error" => "url and email are required"} = json_response(conn, 422)
    end

    test "returns 422 when only url is provided", %{conn: conn} do
      conn = post(conn, "/api/opt-out", %{url: "https://example.com"})
      assert %{"error" => "url and email are required"} = json_response(conn, 422)
    end

    test "does not require authentication", %{conn: conn} do
      insert(:discovered_source, url: "https://noauth.com")

      # No auth headers — should still work
      conn =
        post(conn, "/api/opt-out", %{
          url: "https://noauth.com",
          email: "test@noauth.com"
        })

      assert json_response(conn, 200)
    end
  end
end
