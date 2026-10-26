defmodule StacksWeb.Plugs.SessionCookieTest do
  @moduledoc """
      The cookie transport, and the counter the bearer deletion is decided on.

      ⛔ THE COUNTER IS WHAT THESE CASES EXIST FOR. It is the load-bearing part
      of the rollout and the thing most likely to be dropped as incidental,
      because without it "delete the bearer path" is a guess —
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
  @rejected_event [:stacks, :auth, :session_cookie_rejected]
  @samesite_event [:stacks, :auth, :samesite_support]

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

    rejected_handler = "cookie-rejected-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      rejected_handler,
      @rejected_event,
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:rejected, measurements, metadata})
      end,
      nil
    )

    samesite_handler = "samesite-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      samesite_handler,
      @samesite_event,
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:samesite, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      :telemetry.detach(rejected_handler)
      :telemetry.detach(samesite_handler)
    end)

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

  # ⛔ THE P1 THIS CLOSES, and it was unreachable when it was introduced — which
  # is what made it dangerous rather than harmless.
  #
  # `OptionalAuthPipeline` had no cookie plug, so a cookie-carried session was
  # ANONYMOUS on all 15 routes behind it. Anonymity there is not a 401, it is
  # **wrong data with a 200**: `Social.blocked?/2` has a `blocked?(nil, _)`
  # clause returning `false`, so a reader who blocked someone would see their
  # content again; `Visibility.viewable_shelves/2` would take the anonymous
  # scope and drop shelves the reader holds grants for.
  #
  # ⚠️ It was masked because the login body still carries the token and the SPA
  # still sends the header — so the gap would have bitten exactly when the
  # bearer path was deleted, on the authority of a counter that lived only in
  # the OTHER pipeline and would have read 100% cookie.
  describe "an optional-auth route sees a cookie-carried reader" do
    test "the reader is identified, not treated as anonymous", %{
      conn: conn,
      user: user,
      token: token
    } do
      conn =
        conn
        |> put_req_cookie(SessionCookie.cookie_name(), token)
        |> get("/api/u/#{user.handle}")

      assert conn.status == 200

      # ⚠️ Asserted on the TRANSPORT COUNTER rather than on page content,
      # deliberately. The counter fires only when `current_resource` is present,
      # so `:cookie` here is direct evidence that the pipeline resolved this
      # reader from the cookie — where a body assertion would be testing the
      # profile endpoint's shape instead of the pipeline's behaviour.
      assert_receive {:transport, %{count: 1}, %{transport: :cookie}}
    end

    # ⚖️ The discriminator fell out of the measurement rather than being
    # designed: the factory's profile is owner-visible, so this route answers
    # **404 anonymously and 200 with the cookie**. That difference is stronger
    # evidence than any body assertion — the same request, the same route, and
    # the cookie is the only thing that changes who the server thinks is asking.
    test "an anonymous request stays anonymous, and is counted as neither", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, "/api/u/#{user.handle}")

      refute conn.status == 200,
             "an owner-visible profile must not be readable anonymously — if this starts " <>
               "returning 200, the cookie case above no longer discriminates"

      refute_receive {:transport, _, _}
    end

    test "the bearer path on an optional-auth route is counted too", %{
      conn: conn,
      user: user,
      token: token
    } do
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/u/#{user.handle}")

      # ⛔ Counting bearer HERE is the half that fixes the evidence base: without
      # it the deletion gate would be blind to the pipeline where losing the
      # header returns wrong data rather than a 401.
      assert_receive {:transport, %{count: 1}, %{transport: :bearer}}
    end
  end

  # ⛔ THE COMPANION INSTRUMENT, and the reason it exists is the state the
  # transport counter CANNOT represent: a present-but-unusable cookie falls
  # through to bearer and is counted `:bearer`, exactly like no cookie at all.
  # During a migration that is the expected initial reading — so a systemic
  # cookie failure looks like "the rollout has not started".
  describe "a cookie that fails to verify" do
    test "is counted as a rejection, with a bounded reason", %{conn: conn} do
      conn
      |> put_req_cookie(SessionCookie.cookie_name(), "not-a-token")
      |> authenticated_get()

      assert_receive {:rejected, %{count: 1}, %{reason: reason}}

      # ⚠️ The label is bounded to Guardian's own atoms (or `:other`), because
      # the value feeding it is client-controlled and an unbounded counter label
      # is a cardinality leak.
      assert reason in [
               :invalid_token,
               :token_expired,
               :invalid_issuer,
               :invalid_audience,
               :not_found,
               :other
             ]
    end

    # ⛔ THE BOUND IS TESTED DIRECTLY, because through HTTP it CANNOT be.
    #
    # MEASURED: a probe making the label unbounded left the whole suite green —
    # every rejection reachable through a request lands in the known list, so
    # the assertion above cannot distinguish a bounded mapping from an unbounded
    # one. The `:other` clause exists for a reason Guardian has not returned
    # yet, which is exactly the input no request can produce.
    #
    # ⚠️ It is also the security-relevant clause: the label is fed by a
    # client-controlled value, so unbounded means a metric-cardinality leak. A
    # guard whose only untested clause is the one that matters is the wrong way
    # round, which is why the function is public rather than the test dropped.
    test "an unrecognised rejection collapses to :other rather than leaking its value" do
      assert SessionCookie.reject_label(:invalid_token) == :invalid_token
      assert SessionCookie.reject_label({:token_expired, "exp"}) == :token_expired

      # The inputs no HTTP request can produce, which is the whole point.
      assert SessionCookie.reject_label(:some_future_guardian_atom) == :other
      assert SessionCookie.reject_label({:nested, {:weird, "shape"}}) == :other
      assert SessionCookie.reject_label("a string from somewhere") == :other
    end

    # ⛔ The discriminating half: the two states the transport counter conflates
    # must be DISTINGUISHABLE here, or this counter adds nothing. No cookie at
    # all must emit no rejection.
    test "no cookie at all emits no rejection, so the two states are distinguishable",
         %{conn: conn, token: token} do
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> authenticated_get()

      assert_receive {:transport, %{count: 1}, %{transport: :bearer}}
      refute_receive {:rejected, _, _}
    end

    # ⚠️ And the shape that makes this worth having: the SAME transport reading
    # (`:bearer`) with and without a broken cookie. If this ever fails, the two
    # counters have stopped being independent and the rejection series has
    # started leaking into the deletion gate's evidence.
    test "a broken cookie still reads as :bearer on the transport series",
         %{conn: conn, token: token} do
      conn
      |> put_req_cookie(SessionCookie.cookie_name(), "not-a-token")
      |> put_req_header("authorization", "Bearer " <> token)
      |> authenticated_get()

      assert_receive {:transport, %{count: 1}, %{transport: :bearer}}
      assert_receive {:rejected, %{count: 1}, _}
    end
  end

  # ⛔ THE SIZING COUNTER, and the cases are about what could corrupt the number
  # rather than about whether it fires.
  #
  # It exists because a pending decision — whether a double-submit CSRF token is
  # worth a 77-call-site refactor plus an enforcement step that can reject
  # writes — turns on how much authenticated traffic comes from clients that
  # ignore SameSite. ⚠️ Nothing in this application recorded an inbound user
  # agent before, so the question was unanswerable from existing data.
  describe "the SameSite sizing counter" do
    @modern_chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

    test "classifies an authenticated request's client", %{conn: conn, token: token} do
      conn
      |> put_req_cookie(SessionCookie.cookie_name(), token)
      |> put_req_header("user-agent", @modern_chrome)
      |> authenticated_get()

      assert_receive {:samesite, %{count: 1}, %{enforces: :enforces}}
    end

    # ⛔ The population the decision is actually about.
    test "counts a client that ignores SameSite as does_not_enforce",
         %{conn: conn, token: token} do
      conn
      |> put_req_cookie(SessionCookie.cookie_name(), token)
      |> put_req_header(
        "user-agent",
        "Mozilla/5.0 (Windows NT 6.1; Trident/7.0; rv:11.0) like Gecko"
      )
      |> authenticated_get()

      assert_receive {:samesite, %{count: 1}, %{enforces: :does_not_enforce}}
    end

    # ⚠️ A missing header must be :unknown and never :enforces. Defaulting to
    # enforcement would make the residual population look smaller than it is —
    # the direction that argues for skipping the refactor.
    test "a request with no user-agent header is unknown, not assumed safe",
         %{conn: conn, token: token} do
      conn
      |> put_req_cookie(SessionCookie.cookie_name(), token)
      |> authenticated_get()

      assert_receive {:samesite, %{count: 1}, %{enforces: :unknown}}
    end

    # ⛔ AUTHENTICATED ONLY, and the scoping is load-bearing: anonymous traffic
    # has no session to forge, so including it would dilute the figure IN THE
    # DIRECTION OF LOOKING RISKIER than it is — pushing the decision toward the
    # expensive option on a number that overstates the threat.
    test "an unauthenticated request is not counted at all", %{conn: conn} do
      conn
      |> put_req_header("user-agent", @modern_chrome)
      |> authenticated_get()

      refute_receive {:samesite, _, _}
    end

    # ⚠️ It must fire on the bearer path too, or the figure is scoped to cookie
    # sessions and silently answers a narrower question than the one asked.
    test "fires regardless of which transport carried the session",
         %{conn: conn, token: token} do
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("user-agent", @modern_chrome)
      |> authenticated_get()

      assert_receive {:transport, %{count: 1}, %{transport: :bearer}}
      assert_receive {:samesite, %{count: 1}, %{enforces: :enforces}}
    end
  end
end
