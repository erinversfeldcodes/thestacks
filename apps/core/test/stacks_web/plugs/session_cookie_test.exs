defmodule StacksWeb.Plugs.SessionCookieTest do
  @moduledoc """
      The cookie transport, and the counter the bearer deletion is decided on.

      ⛔ THE COUNTER IS WHAT THESE CASES EXIST FOR. #506 records that it is "the
      load-bearing part of the rollout and the thing most likely to be dropped
      as incidental", because without it "delete the bearer path" is a guess —
      and this repository has a dual path that became permanent because nothing
      measured which half was live. A counter that reports the WRONG transport
      is worse than none: it would license the deletion on false evidence.

      So the cases below are not "does the cookie work". They are:
      which transport does the counter name, in each state a real request can
      arrive in — including the one where both transports are present.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias StacksWeb.Plugs.SessionCookie

  @event [:stacks, :auth, :session_transport]

  setup do
    handler = "session-transport-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      @event,
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:transport, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The factory confirms by default; `RequireConfirmedEmail` is in the pipeline.
    user = insert(:user)
    {:ok, token, _claims} = Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  defp authenticated_get(conn), do: get(conn, "/api/auth/me")

  describe "a session carried by cookie" do
    test "authenticates a request with no Authorization header", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_cookie(SessionCookie.cookie_name(), token)
        |> authenticated_get()

      assert conn.status == 200
    end

    test "is counted as :cookie", %{conn: conn, token: token} do
      conn
      |> put_req_cookie(SessionCookie.cookie_name(), token)
      |> authenticated_get()

      assert_receive {:transport, %{count: 1}, %{transport: :cookie}}
    end
  end

  describe "the bearer transport still works during the rollout" do
    test "authenticates a request with no cookie", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> authenticated_get()

      assert conn.status == 200
    end

    # ⛔ The half that makes the deletion decidable. If a bearer request were
    # counted as `:cookie`, the bearer series would read zero while the bearer
    # path was the only thing working — and the rollout would delete it on that
    # reading.
    test "is counted as :bearer", %{conn: conn, token: token} do
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> authenticated_get()

      assert_receive {:transport, %{count: 1}, %{transport: :bearer}}
    end
  end

  # ⛔ THE DISCRIMINATING CASE, and the reason the plug reads the transport from
  # `conn.private` rather than re-deriving it at response time. A client
  # mid-migration sends BOTH: a cookie it was given and a bearer header it has
  # not stopped sending. Re-deriving ("is a cookie present?") would answer a
  # different question from "which one authenticated this request".
  describe "when both transports are present" do
    test "the cookie is what authenticates, and the count says so", %{conn: conn, token: token} do
      conn
      |> put_req_cookie(SessionCookie.cookie_name(), token)
      |> put_req_header("authorization", "Bearer " <> token)
      |> authenticated_get()

      assert_receive {:transport, %{count: 1}, %{transport: :cookie}}
    end

    # ⚠️ And the inverse, which is the state that would have been invisible: a
    # STALE cookie beside a live bearer header. The request must still
    # authenticate — on the header — and must be counted as `:bearer`, because
    # counting it as `:cookie` is exactly how the bearer series reads zero while
    # the bearer path carries the traffic.
    test "a junk cookie does not shadow a live header, in either the outcome or the count",
         %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_cookie(SessionCookie.cookie_name(), "not-a-token")
        |> put_req_header("authorization", "Bearer " <> token)
        |> authenticated_get()

      assert conn.status == 200
      assert_receive {:transport, %{count: 1}, %{transport: :bearer}}
    end
  end

  # ⛔ ONLY AUTHENTICATED REQUESTS ARE COUNTED. Without this the bearer series
  # could be held at zero by a stream of failures, and "bearer is at zero"
  # would be satisfied by nobody successfully using it rather than by nobody
  # using it.
  describe "requests that do not authenticate" do
    test "an absent session is refused and counted as neither transport", %{conn: conn} do
      conn = authenticated_get(conn)

      assert conn.status == 401
      refute_receive {:transport, _, _}
    end

    test "an invalid cookie is refused and counted as neither transport", %{conn: conn} do
      conn =
        conn
        |> put_req_cookie(SessionCookie.cookie_name(), "not-a-token")
        |> authenticated_get()

      assert conn.status == 401
      refute_receive {:transport, _, _}
    end
  end

  describe "the cookie's attributes" do
    # ⚠️ Asserted on the written header rather than on the helper's arguments,
    # because the attributes are the security claim and a helper can be correct
    # while the header it produces is not.
    test "are HttpOnly, Secure and SameSite=Lax", %{conn: conn, token: token} do
      # ⚠️ SENT, not just built. `put_resp_cookie/4` writes `conn.resp_cookies`;
      # the `set-cookie` HEADER is only materialised on send. Asserting on
      # `resp_cookies` would be asserting the helper's own arguments back at
      # itself — the layer this case exists to get past.
      [set_cookie] =
        conn
        |> SessionCookie.put_session_cookie(token, 3600)
        |> Plug.Conn.send_resp(200, "")
        |> Plug.Conn.get_resp_header("set-cookie")

      assert set_cookie =~ "#{SessionCookie.cookie_name()}=#{token}"
      assert set_cookie =~ "HttpOnly"
      assert set_cookie =~ "secure"
      assert set_cookie =~ "SameSite=Lax"
    end

    # ⛔ Clearing must carry the SAME attributes, not just the name. A cookie is
    # identified by name plus path plus domain, so a mismatched deletion leaves
    # the original in place — a logout that reports success while the session
    # keeps being replayed.
    test "are repeated on deletion, so the clear actually matches", %{conn: conn} do
      [set_cookie] =
        conn
        |> SessionCookie.delete_session_cookie()
        |> Plug.Conn.send_resp(200, "")
        |> Plug.Conn.get_resp_header("set-cookie")

      assert set_cookie =~ "#{SessionCookie.cookie_name()}="
      assert set_cookie =~ "HttpOnly"
      assert set_cookie =~ "secure"
      assert set_cookie =~ "SameSite=Lax"
    end
  end
end
