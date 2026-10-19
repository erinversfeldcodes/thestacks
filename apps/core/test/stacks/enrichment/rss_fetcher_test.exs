defmodule Stacks.Enrichment.RssFetcherTest do
  @moduledoc """
      Transport-bound proofs for the real fetcher.

      These are the only tests in the suite that speak HTTP for real, and they do
      it to **127.0.0.1**, against listeners this module starts and stops. Nothing
      leaves the machine. Their job is to prove that the bounds `RssFetcher` sets
      actually reach the socket, so that a hostile or broken peer cannot park an
      Oban worker indefinitely in production.
  """
  use ExUnit.Case, async: true

  alias Stacks.Enrichment.RssFetcher

  @tiny_bounds [receive_timeout: 500, request_timeout: 1_000]
  defp start_handshake_staller do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      case :gen_tcp.accept(lsock) do
        {:ok, _sock} -> Process.sleep(:infinity)
        _ -> :ok
      end
    end)

    on_exit(fn -> :gen_tcp.close(lsock) end)
    port
  end

  defp start_trickler do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      with {:ok, sock} <- :gen_tcp.accept(lsock),
           {:ok, _req} <- :gen_tcp.recv(sock, 0, 5_000) do
        dribble(sock, "HTTP/1.1 200 OK\r\n")
        Process.sleep(:infinity)
      end
    end)

    on_exit(fn -> :gen_tcp.close(lsock) end)
    port
  end

  defp dribble(sock, payload) do
    Enum.each(String.graphemes(payload), fn byte ->
      :gen_tcp.send(sock, byte)
      Process.sleep(2_000)
    end)
  end

  describe "the production bounds themselves" do
    test "every operation ships both timeouts, at the values the module documents" do
      for op <- [:probe, :fetch] do
        opts = RssFetcher.request_opts(op)

        assert is_integer(opts[:receive_timeout]) and opts[:receive_timeout] > 0,
               "#{op} has no receive_timeout — each chunk is unbounded"

        assert is_integer(opts[:request_timeout]) and opts[:request_timeout] > 0,
               "#{op} has no request_timeout — a dribbling peer parks an Oban worker " <>
                 "(measured: 35_017ms under receive_timeout alone)"
      end
    end
  end

  describe "probe/1 transport bounds" do
    @tag timeout: 120_000
    test "returns rather than hanging when the peer stalls the TLS handshake" do
      port = start_handshake_staller()

      result = RssFetcher.probe("https://127.0.0.1:#{port}/feed", @tiny_bounds)

      # Structural, for the same reason as its sibling below: the connect phase
      # being bounded is now observable in the return value, so the 50-second
      # wall-clock ceiling this used to carry is gone. The staller never
      # completes the TLS handshake, so only the bound can produce this.
      assert {:error, {:transport, :timeout}} = result
    end

    test "returns rather than hanging when the peer dribbles the response forever" do
      port = start_trickler()

      result = RssFetcher.probe("http://127.0.0.1:#{port}/feed", @tiny_bounds)

      # ⛔ STRUCTURAL, not a stopwatch, and that swap is the whole point.
      #
      # This used to assert `{:error, _}` — which any failure satisfies — plus
      # `elapsed_ms < 10_000`. The loose match was the problem: `probe/1`
      # collapsed every non-2xx outcome to `:not_found`, so the return value
      # could not say whether the 1s `request_timeout` had fired, and the wall
      # clock was the only signal left. A wall clock cannot tell a missing bound
      # from a busy machine: this failed at 11,821ms against the 10,000ms
      # ceiling under load while being 3/3 green idle.
      #
      # `probe/1` now distinguishes a transport failure from a status, so the
      # bound firing is observable. The trickler dribbles "HTTP/1.1 200 OK" one
      # byte per 2s — 34 seconds for the status line alone — so ONLY the timeout
      # can produce this result. A missing bound would hang, and ExUnit's own
      # `@tag timeout:` is the hang detector; it does not need an assertion.
      assert {:error, {:transport, :timeout}} = result
    end

    test "returns an error, not a 2xx, for a peer that never answers" do
      port = start_handshake_staller()

      assert {:error, _} = RssFetcher.probe("https://127.0.0.1:#{port}/feed")
    end
  end

  describe "fetch_and_parse/1 transport bounds" do
    test "returns rather than hanging when the peer dribbles the response forever" do
      port = start_trickler()

      result = RssFetcher.fetch_and_parse("http://127.0.0.1:#{port}/feed.xml", @tiny_bounds)

      # Structural, like its `probe/2` siblings. ⚠️ A DIFFERENT shape, though,
      # and deliberately asserted as such: `fetch_and_parse/2` passes the Finch
      # error straight through, while `probe/2` now wraps it as
      # `{:transport, reason}` because its callers only ever had a flattened
      # atom. Two sibling functions reporting the same condition two ways is a
      # smell worth recording — but widening `fetch_and_parse/2`'s contract has
      # more callers than this change should touch, so the inconsistency is
      # named here rather than papered over with a looser match.
      assert {:error, %Finch.TransportError{reason: :timeout}} = result
    end
  end
end
