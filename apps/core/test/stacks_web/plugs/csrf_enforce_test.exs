defmodule StacksWeb.Plugs.CsrfEnforceTest do
  @moduledoc """
      Enforcement: what it refuses, what it must never refuse, and whether the
      refusal says enough to act on.
  """
  use CoreWeb.ConnCase, async: false

  alias StacksWeb.Plugs.CsrfCookie
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
    # ⛔ The counter must see a request BEFORE enforcement turns it away, or
    # enforcement hides the signal that says whether enforcement is correct.
    test "the router runs the counter before the enforcer" do
      router = File.read!("lib/core_web/router.ex")
      counter_at = :binary.match(router, "CsrfCounter") |> elem(0)
      enforce_at = :binary.match(router, "CsrfEnforce") |> elem(0)

      assert counter_at < enforce_at,
             "CsrfCounter must be piped before CsrfEnforce, or a refused request goes uncounted"
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
