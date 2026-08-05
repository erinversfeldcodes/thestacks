defmodule CoreWeb.PageControllerTest do
  use CoreWeb.ConnCase, async: true

  test "GET / serves index.html", %{conn: conn} do
    conn = get(conn, "/")
    assert conn.status == 200
    [ct | _] = get_resp_header(conn, "content-type")
    assert String.starts_with?(ct, "text/html")
  end

  test "GET /login serves SPA index", %{conn: conn} do
    conn = get(conn, "/login")
    assert conn.status == 200
    [ct | _] = get_resp_header(conn, "content-type")
    assert String.starts_with?(ct, "text/html")
  end

  test "GET /upload serves SPA index", %{conn: conn} do
    conn = get(conn, "/upload")
    assert conn.status == 200
  end

  # #318 TR-4: the consent page folded into Privacy, so its old path 302s there.
  # Proven at the router/controller level so bookmarks and existing links keep
  # working even though the SPA no longer has a /settings/consent page.
  test "GET /settings/consent redirects to /settings/privacy", %{conn: conn} do
    conn = get(conn, "/settings/consent")
    assert redirected_to(conn, 302) == "/settings/privacy"
  end
end
