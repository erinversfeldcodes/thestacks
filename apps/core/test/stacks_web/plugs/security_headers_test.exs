defmodule StacksWeb.Plugs.SecurityHeadersTest do
  use CoreWeb.ConnCase, async: true

  alias StacksWeb.Plugs.SecurityHeaders

  describe "call/2" do
    test "sets x-content-type-options header", %{conn: conn} do
      opts = SecurityHeaders.init([])
      result = SecurityHeaders.call(conn, opts)
      assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
    end

    test "sets x-frame-options header", %{conn: conn} do
      opts = SecurityHeaders.init([])
      result = SecurityHeaders.call(conn, opts)
      assert get_resp_header(result, "x-frame-options") == ["DENY"]
    end

    test "sets content-security-policy header", %{conn: conn} do
      opts = SecurityHeaders.init([])
      result = SecurityHeaders.call(conn, opts)
      [csp] = get_resp_header(result, "content-security-policy")
      assert String.contains?(csp, "default-src 'self'")
    end

    test "CSP connect-src whitelists R2 for presigned-URL uploads", %{conn: conn} do
      opts = SecurityHeaders.init([])
      result = SecurityHeaders.call(conn, opts)
      [csp] = get_resp_header(result, "content-security-policy")

      [_, connect_src] = Regex.run(~r/connect-src([^;]*)/, csp)

      assert String.contains?(connect_src, "https://*.r2.cloudflarestorage.com"),
             "connect-src must allow R2 (uploads PUT directly to " <>
               "<account>.r2.cloudflarestorage.com); without it the browser " <>
               "blocks the PUT and uploads fail silently. Got: #{connect_src}"
    end
  end
end
