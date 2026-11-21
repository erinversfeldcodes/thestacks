defmodule CoreWeb.PageControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Core.AppRole

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

  test "GET /settings/consent redirects to /settings/privacy", %{conn: conn} do
    conn = get(conn, "/settings/consent")
    assert redirected_to(conn, 302) == "/settings/privacy"
  end

  describe "GET /u/:handle — the search-indexing crawl directive (fail-closed)" do
    # Each request is driven inside the Core.AppRole lane so the handle lookup and
    # the consent read run as `stacks_app` (RLS applies), not the superuser the
    # test connection would otherwise use.
    test "a PUBLIC, OPTED-IN profile serves index", %{conn: conn} do
      user =
        insert(:user, handle: "mara", profile_visibility: "public", consent_search_indexing: true)

      conn = AppRole.as_app_role(fn -> get(conn, "/u/#{user.handle}") end)

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["index, follow"]
    end

    test "a public profile that has NOT opted in serves noindex", %{conn: conn} do
      user =
        insert(:user,
          handle: "nolan",
          profile_visibility: "public",
          consent_search_indexing: false
        )

      conn = AppRole.as_app_role(fn -> get(conn, "/u/#{user.handle}") end)
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    test "an opted-in but NON-public profile serves noindex (opt-in alone is not enough)",
         %{conn: conn} do
      user =
        insert(:user,
          handle: "platty",
          profile_visibility: "platform",
          consent_search_indexing: true
        )

      conn = AppRole.as_app_role(fn -> get(conn, "/u/#{user.handle}") end)
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    test "an unknown handle serves noindex", %{conn: conn} do
      conn = AppRole.as_app_role(fn -> get(conn, "/u/ghost") end)
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    test "a non-profile SPA route serves noindex", %{conn: conn} do
      conn = get(conn, "/library")
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end
  end
end
