defmodule Stacks.Enrichment.RssFetcherTest do
  @moduledoc """
  Transport-bound proofs for the real fetcher (#377).

  These are the only tests in the suite that speak HTTP for real, and they do
  it to **127.0.0.1**, against listeners this module starts and stops. Nothing
  leaves the machine. Their job is to prove that the bounds `RssFetcher` sets
  actually reach the socket, so that a hostile or broken peer cannot park an
  Oban worker indefinitely in production.
  """
  use ExUnit.Case, async: true

  alias Stacks.Enrichment.RssFetcher

  # Generous enough that a slow CI box will not flake, tight enough that
  # removing the bound under test blows it: without `request_timeout` the
  # probe's trickle case ran 35_017ms, and ExUnit's own limit is 60_000ms.
  @must_return_within_ms 20_000

  # `fetch_and_parse/1` is allowed a longer whole-request budget than the probe
  # (20s vs 5s) because it downloads a document rather than just asking whether
  # one is there. Unbounded, the trickle case runs ~49s (34s of dribble plus a
  # final 15s `receive_timeout`), so this still reddens if the bound is dropped.
  @fetch_must_return_within_ms 30_000

  # Accepts the TCP connection, then never speaks TLS. This is the exact shape
  # of the #377 stacktrace: the hang was inside `:ssl_gen_statem.handshake/2`,
  # i.e. after the TCP connect had already succeeded.
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

  # Completes the connect, then dribbles the response one byte every 2s —
  # each byte comfortably inside `receive_timeout: 5_000`, but never ending.
  # This is what `receive_timeout` alone does NOT catch.
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

  defp time(fun) do
    {micros, result} = :timer.tc(fun)
    {div(micros, 1000), result}
  end

  describe "probe/1 transport bounds" do
    test "returns rather than hanging when the peer stalls the TLS handshake" do
      port = start_handshake_staller()

      {elapsed_ms, result} = time(fn -> RssFetcher.probe("https://127.0.0.1:#{port}/feed") end)

      assert {:error, _} = result

      assert elapsed_ms < @must_return_within_ms,
             "connect phase was not bounded: took #{elapsed_ms}ms"
    end

    test "returns rather than hanging when the peer dribbles the response forever" do
      port = start_trickler()

      {elapsed_ms, result} = time(fn -> RssFetcher.probe("http://127.0.0.1:#{port}/feed") end)

      assert {:error, _} = result

      # ⚠️ This is the assertion that `receive_timeout` alone cannot satisfy.
      # `receive_timeout` bounds each CHUNK; only `request_timeout` bounds the
      # whole response. Drop `request_timeout` from RssFetcher.probe/1 and this
      # goes from ~5s to ~35s.
      assert elapsed_ms < @must_return_within_ms,
             "receive phase was not bounded: took #{elapsed_ms}ms"
    end

    test "returns an error, not a 2xx, for a peer that never answers" do
      port = start_handshake_staller()

      assert {:error, _} = RssFetcher.probe("https://127.0.0.1:#{port}/feed")
    end
  end

  describe "fetch_and_parse/1 transport bounds" do
    test "returns rather than hanging when the peer dribbles the response forever" do
      port = start_trickler()

      {elapsed_ms, result} =
        time(fn -> RssFetcher.fetch_and_parse("http://127.0.0.1:#{port}/feed.xml") end)

      assert {:error, _} = result

      assert elapsed_ms < @fetch_must_return_within_ms,
             "receive phase was not bounded: took #{elapsed_ms}ms"
    end
  end
end
