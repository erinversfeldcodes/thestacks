defmodule StacksWeb.Plugs.CsrfCookieTest do
  @moduledoc """
      The readable CSRF cookie, and the properties a later reader is most likely
      to break while believing they are improving it.
  """
  use CoreWeb.ConnCase, async: true

  alias StacksWeb.Plugs.CsrfCookie

  defp set_cookie_header(conn) do
    conn
    |> Plug.Conn.send_resp(200, "")
    |> Plug.Conn.get_resp_header("set-cookie")
    |> Enum.find(&String.starts_with?(&1, CsrfCookie.cookie_name() <> "="))
  end

  describe "issuing" do
    test "a request with no cookie gets one", %{conn: conn} do
      header = conn |> CsrfCookie.call([]) |> set_cookie_header()

      assert header
      assert header =~ ~r/#{CsrfCookie.cookie_name()}=[A-Za-z0-9_-]{20,}/
    end

    # ⚠️ Re-issuing on every page load would rotate the token out from under any
    # other tab the reader has open, and that tab's next write would be refused
    # with nothing to explain it.
    test "a request that already has one is left alone", %{conn: conn} do
      header =
        conn
        |> Plug.Test.put_req_cookie(CsrfCookie.cookie_name(), "already-here")
        |> CsrfCookie.call([])
        |> set_cookie_header()

      refute header
    end

    # ⚠️ An empty cookie is not a token. Treating it as one would leave the
    # client echoing "" and the server comparing "" to "" — a check that passes
    # while proving nothing.
    test "an empty cookie is replaced rather than accepted", %{conn: conn} do
      header =
        conn
        |> Plug.Test.put_req_cookie(CsrfCookie.cookie_name(), "")
        |> CsrfCookie.call([])
        |> set_cookie_header()

      assert header
    end
  end

  describe "the attributes, each for a stated reason" do
    setup %{conn: conn} do
      %{header: conn |> CsrfCookie.call([]) |> set_cookie_header()}
    end

    # ⛔ THE ONE THAT LOOKS LIKE A BUG. Every other cookie in this wave is
    # HttpOnly; this one must not be, because the SPA has to READ it to echo it
    # in a header. Making it HttpOnly fails silently — the header simply stops
    # being sent — and then enforcement refuses every write.
    test "it is NOT HttpOnly, because the client must read it", %{header: header} do
      refute header =~ ~r/HttpOnly/i
    end

    test "it is Secure", %{header: header} do
      assert header =~ ~r/secure/i
    end

    # ⚠️ Lax, not Strict: Strict withholds the cookie on a top-level navigation
    # INTO the site, so a reader following a link from elsewhere would land
    # without a token and their first write would fail.
    test "it is SameSite=Lax", %{header: header} do
      assert header =~ ~r/SameSite=Lax/i
    end

    # ⚠️ Longer than a session on purpose: the token is a same-origin proof, not
    # a credential, and expiring it with the session would log nobody out while
    # leaving an open page unable to write.
    test "it outlives a session", %{header: header} do
      assert header =~ ~r/max-age=#{CsrfCookie.max_age()}/i
      assert CsrfCookie.max_age() > 60 * 60 * 24
    end
  end

  describe "the token itself" do
    # ⚠️ The value travels in a header as well as a cookie, so the alphabet is
    # URL-safe: a `+` or `/` is legal in a header but invites double-encoding
    # bugs at every layer that touches it.
    test "is URL-safe and unpadded" do
      token = CsrfCookie.generate_token()

      assert token =~ ~r/\A[A-Za-z0-9_-]+\z/
      refute String.contains?(token, "=")
    end

    # ⛔ The anti-vacuity case. A constant token would satisfy every assertion
    # above — same shape, same alphabet, same length — and prove nothing, since
    # an attacker who learns one victim's token would hold everyone's.
    test "differs between issues" do
      tokens = for _ <- 1..50, do: CsrfCookie.generate_token()

      assert length(Enum.uniq(tokens)) == 50
    end

    test "carries enough entropy to be unguessable" do
      # 32 raw bytes -> 43 unpadded base64 characters.
      assert String.length(CsrfCookie.generate_token()) >= 43
    end
  end

  describe "wiring" do
    # ⛔ A plug nothing invokes is not a plug. The whole scheme rests on this
    # cookie existing before the SPA's first write, so the SPA's own response is
    # the thing to assert against — not the plug in isolation.
    test "the SPA's HTML response carries the cookie", %{conn: conn} do
      conn = get(conn, "/")

      header =
        conn
        |> Plug.Conn.get_resp_header("set-cookie")
        |> Enum.find(&String.starts_with?(&1, CsrfCookie.cookie_name() <> "="))

      assert header, "the SPA page must issue the CSRF cookie, or no write can prove itself"
      refute header =~ ~r/HttpOnly/i
    end
  end
end
