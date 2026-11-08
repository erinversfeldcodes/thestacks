defmodule StacksWeb.Plugs.CsrfEnforceTest do
  @moduledoc """
      Enforcement: what it refuses, what it must never refuse, and whether the
      refusal says enough to act on.
  """
  use CoreWeb.ConnCase, async: false

  alias StacksWeb.Plugs.CsrfCookie
  alias StacksWeb.Plugs.CsrfCounter
  alias StacksWeb.Plugs.CsrfEnforce

  # ⛔ A BARE conn, not the proven one `ConnCase` provides. These cases are
  # about what happens WITHOUT a proof, so inheriting one would turn every
  # absent-case into a present-case and the suite would assert nothing.
  defp bare(method), do: %{Phoenix.ConnTest.build_conn() | method: method}
  defp write(_conn, method \\ "POST"), do: bare(method)
  defp with_cookie(conn, v), do: Plug.Test.put_req_cookie(conn, CsrfCookie.cookie_name(), v)
  defp with_header(conn, v), do: Plug.Conn.put_req_header(conn, "x-csrf-token", v)

  describe "what it lets through" do
    test "a proven write passes", %{conn: conn} do
      result = conn |> write() |> with_cookie("t") |> with_header("t") |> CsrfEnforce.call([])

      refute result.halted
    end

    # ⛔ THE ONE THAT MUST NEVER BREAK. Reads are the overwhelming majority of
    # traffic and carry no proof by design; refusing one would take the site
    # down for everyone, signed in or not.
    test "every safe method passes, with or without a proof", %{conn: conn} do
      for method <- ["GET", "HEAD", "OPTIONS"] do
        refute conn |> write(method) |> CsrfEnforce.call([]) |> Map.fetch!(:halted),
               "#{method} must never be refused"

        refute conn
               |> write(method)
               |> with_cookie("a")
               |> with_header("b")
               |> CsrfEnforce.call([])
               |> Map.fetch!(:halted),
               "#{method} must not be refused even for a mismatch"
      end
    end
  end

  describe "what it refuses" do
    test "a write with no header", %{conn: conn} do
      result = conn |> write() |> with_cookie("t") |> CsrfEnforce.call([])

      assert result.halted
      assert result.status == 403
    end

    test "a write with no cookie", %{conn: conn} do
      result = conn |> write() |> with_header("t") |> CsrfEnforce.call([])

      assert result.halted
      assert result.status == 403
    end

    test "a write whose header and cookie disagree", %{conn: conn} do
      result = conn |> write() |> with_cookie("a") |> with_header("b") |> CsrfEnforce.call([])

      assert result.halted
      assert result.status == 403
    end

    test "every unsafe verb is refused, not just POST", %{conn: conn} do
      for method <- ["POST", "PUT", "PATCH", "DELETE"] do
        assert conn |> write(method) |> CsrfEnforce.call([]) |> Map.fetch!(:halted),
               "#{method} must be refused when unproven"
      end
    end

    # ⛔ Two empty strings compare equal. Without the emptiness check this would
    # be the hole the whole scheme rests on: a request with an empty cookie and
    # an empty header would prove itself.
    test "empty values do not prove anything", %{conn: conn} do
      result = conn |> write() |> with_cookie("") |> with_header("") |> CsrfEnforce.call([])

      assert result.halted
    end
  end

  describe "the refusal is attributable" do
    # ⛔ MOST OF THIS PLUG'S VALUE. A bare 403 turns a client bug into an
    # afternoon; the three reasons are three different fixes.
    test "a missing header says so, and distinguishably from a missing cookie",
         %{conn: conn} do
      missing_header =
        conn |> write() |> with_cookie("t") |> CsrfEnforce.call([]) |> response_body()

      missing_cookie =
        conn |> write() |> with_header("t") |> CsrfEnforce.call([]) |> response_body()

      assert missing_header["reason"] == "absent_header"
      assert missing_cookie["reason"] == "absent_cookie"
      refute missing_header["detail"] == missing_cookie["detail"]
    end

    test "a mismatch is its own reason, being the only attack-shaped one", %{conn: conn} do
      body =
        conn
        |> write()
        |> with_cookie("a")
        |> with_header("b")
        |> CsrfEnforce.call([])
        |> response_body()

      assert body["reason"] == "mismatched"
    end

    test "the detail names the header and the cookie a client must use", %{conn: conn} do
      body = conn |> write() |> with_cookie("t") |> CsrfEnforce.call([]) |> response_body()

      assert body["detail"] =~ "X-CSRF-Token"
      assert body["detail"] =~ CsrfCookie.cookie_name()
    end

    # ⛔ NOTHING FROM THE REQUEST REACHES THE RESPONSE. A reflected
    # attacker-chosen value is how a CSRF refusal becomes an injection surface.
    test "an attacker-chosen token is not echoed", %{conn: conn} do
      marker = "<script>pwned</script>"

      body =
        conn
        |> write()
        |> with_cookie("real")
        |> with_header(marker)
        |> CsrfEnforce.call([])
        |> response_body()

      refute Jason.encode!(body) =~ "pwned"
      refute Jason.encode!(body) =~ "script"
    end
  end

  describe "ordering and telemetry" do
    # ⛔ THIS IS THE ONLY CASE THAT PROVES THE PLUG IS REACHED. Every other case
    # in this file calls `CsrfEnforce.call/2` directly, so all of them pass just
    # as happily when the plug is piped nowhere. Moving `plug CsrfEnforce` off
    # the `:api` pipeline left this file, the counter's file,
    # `scripts/check-csrf-scope.sh` and `guard_unbypassable_test.sh` ALL GREEN
    # while none of the 83 state-changing routes was protected — a security gate
    # that could not fire, which is the failure this work exists to prevent.
    #
    # ⚠️ And `ConnCase` hands out a PROVEN conn, so the suite's other 475
    # controller tests would stay green too. Nothing in the local gate set
    # noticed. Hence a bare `build_conn()` driven through the real router.
    #
    # ⚖️ The ordering claim is asserted here too, and behaviourally: the
    # counter's event must arrive even though the enforcer refused the request.
    # The previous version of this case compared BYTE OFFSETS of the two module
    # names in the router source — which a mere comment naming `CsrfEnforce`
    # earlier in the file could turn red, and which stayed green when the two
    # plugs sat in different pipelines with their textual order intact. It was
    # wrong in both directions and is replaced rather than repaired.
    # ⛔ THE EXEMPTION, DRIVEN THROUGH THE REAL ROUTER WITH A BARE CONN. Four
    # artefacts said the partner routes were "deliberately outside" CSRF
    # enforcement — this plug's moduledoc, `CsrfCounter`'s, `EXPECTED_PARTNER=4`
    # in the scope gate, and the generated scope document — while no code
    # carried it out, and every one of the four state-changing partner routes
    # answered 403.
    #
    # ⚠️ THE WHOLE SUITE WAS BLIND TO IT: `CoreWeb.ConnCase`'s `proven_conn/0`
    # attaches a `stacks_csrf` cookie AND a matching header to every test conn,
    # so the partner tests inherited a browser-shaped proof a real partner can
    # never have — 13 of them passing against a route that was dead in
    # production. Hence `build_conn()` here, deliberately bare.
    test "a partner write is not refused by CSRF — it has no cookie jar to borrow" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer some-partner-key")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/partner/events", %{"kind" => "reading_group"})

      refute conn.status == 403 and json_response(conn, 403)["error"] == "csrf_check_failed",
             "a server-to-server partner holds an Argon2 key and no cookie jar, so CSRF " <>
               "enforcement must not be what answers it"

      # ⚖️ And it must reach authentication rather than stopping earlier for a
      # different reason: a bad key is a 401, which is the partner pipeline
      # speaking. Asserting only "not 403" would pass if the route 404'd.
      assert conn.status == 401,
             "expected the partner auth pipeline to answer an unknown key, got " <>
               Integer.to_string(conn.status)
    end

    # ⛔ THE SINGULAR/PLURAL CASE, AND IT IS THE ONE THAT MATTERS.
    #
    # `POST /api/partners/register` is PUBLIC, unauthenticated and
    # state-changing — a browser-reachable write that must keep its CSRF
    # protection. Its path_info is ["api", "partners", "register"], one letter
    # away from the exempt ["api", "partner"].
    #
    # ⚠️ The exemption is a SEGMENT-WISE match —
    # `Enum.take(path_info, length(scope)) == scope` — so "partners" ≠ "partner"
    # and this route stays enforced. A `String.starts_with?(request_path,
    # "/api/partner")` version would have exempted it and turned the partner fix
    # into a new CSRF hole on a public write. The case below drives
    # `/api/auth/login`, which shares no prefix at all, so it catches a widening
    # but would stay green against a string-prefix match. This one would not.
    test "a neighbouring route one letter away is still enforced" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/partners/register", %{"name" => "A Bookshop"})

      assert json_response(conn, 403)["error"] == "csrf_check_failed",
             "/api/partners/register is public, unauthenticated and state-changing — " <>
               "it must not inherit the partner scope's exemption"
    end

    # ⛔ ANTI-VACUITY FOR THE EXEMPTION: it must be narrow. A path that merely
    # begins with the same letters is NOT the partner scope, and an exemption
    # matched loosely would silently disable CSRF on neighbouring routes.
    test "the exemption does not leak to routes outside the partner scope" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> post("/api/auth/login", %{email: "nobody@example.test", password: "wrong"})

      assert json_response(conn, 403)["error"] == "csrf_check_failed",
             "an ordinary browser-facing write must still be refused without a proof"
    end

    test "an unproven write is refused BY THE PIPELINE, and counted before it is" do
      ref = :telemetry_test.attach_event_handlers(self(), [CsrfCounter.event()])
      on_exit(fn -> :telemetry.detach(ref) end)

      conn =
        Phoenix.ConnTest.build_conn()
        |> post("/api/auth/login", %{email: "nobody@example.test", password: "wrong"})

      body = json_response(conn, 403)
      assert body["error"] == "csrf_check_failed"
      assert body["reason"] == "absent_header"
      assert conn.halted

      assert_received {_event, _ref, %{count: 1}, %{outcome: :absent_header}}
    end

    test "a refusal emits its reason" do
      ref = :telemetry_test.attach_event_handlers(self(), [CsrfEnforce.event()])
      on_exit(fn -> :telemetry.detach(ref) end)

      build_conn() |> Map.put(:method, "POST") |> CsrfEnforce.call([])

      assert_received {_event, _ref, %{count: 1}, %{reason: :absent_header}}
    end

    test "a proven write emits nothing" do
      ref = :telemetry_test.attach_event_handlers(self(), [CsrfEnforce.event()])
      on_exit(fn -> :telemetry.detach(ref) end)

      build_conn()
      |> Map.put(:method, "POST")
      |> Plug.Test.put_req_cookie(CsrfCookie.cookie_name(), "t")
      |> Plug.Conn.put_req_header("x-csrf-token", "t")
      |> CsrfEnforce.call([])

      refute_received {_event, _ref, _measurements, _meta}
    end
  end

  defp response_body(conn), do: Jason.decode!(conn.resp_body)
end
