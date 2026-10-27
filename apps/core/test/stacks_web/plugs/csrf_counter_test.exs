defmodule StacksWeb.Plugs.CsrfCounterTest do
  @moduledoc """
      The counter that ships before enforcement: it must classify every case
      correctly, and it must not reject anything.
  """
  use CoreWeb.ConnCase, async: false

  alias StacksWeb.Plugs.CsrfCookie
  alias StacksWeb.Plugs.CsrfCounter

  # ⛔ A BARE conn, not the proven one `ConnCase` provides: these cases are
  # about the request WITHOUT a proof.
  defp write(_conn, method \\ "POST") do
    %{Phoenix.ConnTest.build_conn() | method: method}
  end

  defp with_cookie(conn, value) do
    Plug.Test.put_req_cookie(conn, CsrfCookie.cookie_name(), value)
  end

  defp with_header(conn, value) do
    Plug.Conn.put_req_header(conn, CsrfCounter.header_name(), value)
  end

  describe "classification" do
    test "a write carrying a matching header and cookie is proven", %{conn: conn} do
      outcome =
        conn |> write() |> with_cookie("tok-1") |> with_header("tok-1") |> CsrfCounter.outcome()

      assert outcome == :proven
    end

    # ⛔ The two absent outcomes are SEPARATE because they are different bugs.
    # A single `:unproven` label would make a client that forgot the header
    # indistinguishable from a browser that never received a cookie — a client
    # fix versus a server one, in the moment the distinction matters most.
    test "a write with a cookie but no header is absent_header", %{conn: conn} do
      assert conn |> write() |> with_cookie("tok-1") |> CsrfCounter.outcome() == :absent_header
    end

    test "a write with a header but no cookie is absent_cookie", %{conn: conn} do
      assert conn |> write() |> with_header("tok-1") |> CsrfCounter.outcome() == :absent_cookie
    end

    # ⚠️ The only outcome consistent with an attack rather than a mistake, which
    # is why it is not folded into either absence.
    test "a write whose header and cookie differ is mismatched", %{conn: conn} do
      outcome =
        conn |> write() |> with_cookie("tok-1") |> with_header("tok-2") |> CsrfCounter.outcome()

      assert outcome == :mismatched
    end

    # ⛔ THE CASE A NAIVE COMPARE PASSES. Two empty strings compare equal, so a
    # request with an empty cookie and an empty header would read as a proof.
    test "empty values do not count as a proof", %{conn: conn} do
      outcome =
        conn |> write() |> with_cookie("") |> with_header("") |> CsrfCounter.outcome()

      refute outcome == :proven
    end

    # ⚠️ Safe methods are counted rather than skipped, so the series has a
    # denominator: without it, "absent_header is zero" and "this plug never ran"
    # are the same empty result.
    test "reads are counted as safe, not skipped", %{conn: conn} do
      for method <- ["GET", "HEAD", "OPTIONS"] do
        assert conn |> write(method) |> CsrfCounter.outcome() == :safe
      end
    end

    test "every unsafe verb is classified, not just POST", %{conn: conn} do
      for method <- ["POST", "PUT", "PATCH", "DELETE"] do
        outcome = conn |> write(method) |> with_cookie("t") |> with_header("t")

        assert CsrfCounter.outcome(outcome) == :proven
      end
    end
  end

  describe "it counts and does not reject" do
    # ⛔ THE PROPERTY THAT MAKES SHIPPING THIS SAFE. The plug must pass every
    # request through untouched while the client rollout is still in doubt. Not
    # "it happens not to reject" — it must have no halting path at all.
    test "an unproven write is passed through unhalted", %{conn: conn} do
      result = conn |> write() |> CsrfCounter.call([])

      refute result.halted
      assert result.status == nil
    end

    test "a mismatched write is passed through unhalted", %{conn: conn} do
      result =
        conn |> write() |> with_cookie("a") |> with_header("b") |> CsrfCounter.call([])

      refute result.halted
      assert result.status == nil
    end

    # ⚠️ Asserted on the SOURCE, because the two cases above only prove it for
    # the inputs they use. A `halt` added for a fifth outcome would pass them.
    test "the module has no halting path" do
      source = File.read!("lib/stacks_web/plugs/csrf_counter.ex")

      refute source =~ ~r/\bhalt\(/
      refute source =~ ~r/send_resp/
    end
  end

  describe "the telemetry it emits" do
    setup do
      ref = :telemetry_test.attach_event_handlers(self(), [CsrfCounter.event()])
      on_exit(fn -> :telemetry.detach(ref) end)
      :ok
    end

    test "a write emits its outcome", %{conn: conn} do
      conn |> write() |> with_cookie("t") |> with_header("t") |> CsrfCounter.call([])

      assert_received {[:stacks, :auth, :csrf_proof], _ref, %{count: 1}, %{outcome: :proven}}
    end

    test "an unproven write emits absent_header", %{conn: conn} do
      conn |> write() |> with_cookie("t") |> CsrfCounter.call([])

      assert_received {_event, _ref, %{count: 1}, %{outcome: :absent_header}}
    end

    # ⚠️ The denominator: a read must emit too, or a zero on the unproven series
    # cannot be told from the plug never having run.
    test "a read emits safe" do
      build_conn() |> Map.put(:method, "GET") |> CsrfCounter.call([])

      assert_received {_event, _ref, %{count: 1}, %{outcome: :safe}}
    end
  end

  describe "wiring" do
    # ⛔ A counter nothing invokes reads zero, which looks exactly like a counter
    # reporting no problems. The `:api` pipeline is the claim; this drives it.
    test "a real API write goes through the counter", %{conn: conn} do
      ref = :telemetry_test.attach_event_handlers(self(), [CsrfCounter.event()])
      on_exit(fn -> :telemetry.detach(ref) end)

      # Any unsafe route on the :api pipeline; the response does not matter,
      # only that the pipeline ran.
      post(conn, "/api/auth/login", %{email: "nobody@example.test", password: "wrong"})

      assert_received {_event, _ref, %{count: 1}, %{outcome: outcome}}
      assert outcome in [:absent_header, :absent_cookie, :mismatched, :proven]
    end
  end
end
