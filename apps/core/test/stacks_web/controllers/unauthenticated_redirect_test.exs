defmodule StacksWeb.Controllers.UnauthenticatedRedirectTest do
  @moduledoc """
  Confirms that routes in the :authenticated pipeline return 401
  for unauthenticated requests rather than leaking user data.

  Anti-scraping + auth enforcement requirement from Issue #047.
  """

  use CoreWeb.ConnCase, async: true

  describe "unauthenticated access to protected routes" do
    test "GET /api/bookshelves/library without auth returns 401", %{conn: conn} do
      conn = get(conn, "/api/bookshelves/library")
      assert json_response(conn, 401)
    end

    test "GET /api/placements/mine without auth returns 401", %{conn: conn} do
      conn = get(conn, "/api/placements/mine")
      assert json_response(conn, 401)
    end

    test "POST /api/bookshelves/library/placements without auth returns 401", %{conn: conn} do
      conn = post(conn, "/api/bookshelves/library/placements", %{})
      assert json_response(conn, 401)
    end

    test "PUT /api/settings/age_verification without auth returns 401", %{conn: conn} do
      conn = put(conn, "/api/settings/age_verification", %{})
      assert json_response(conn, 401)
    end

    test "DELETE /api/gdpr/account without auth returns 401", %{conn: conn} do
      conn = delete(conn, "/api/gdpr/account")
      assert json_response(conn, 401)
    end

    test "GET /api/auth/me without auth returns 401", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert json_response(conn, 401)
    end
  end
end
