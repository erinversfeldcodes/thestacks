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

  @tiny_bounds [receive_timeout: 500, request_timeout: 1_000]
  @must_return_within_ms 10_000

  @connect_must_return_within_ms 50_000

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

  defp time(fun) do
    {micros, result} = :timer.tc(fun)
    {div(micros, 1000), result}
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

      {elapsed_ms, result} =
        time(fn -> RssFetcher.probe("https://127.0.0.1:#{port}/feed", @tiny_bounds) end)

      assert {:error, _} = result

      assert elapsed_ms < @connect_must_return_within_ms,
             "connect phase was not bounded by the pool transport timeout: took #{elapsed_ms}ms"
    end

    test "returns rather than hanging when the peer dribbles the response forever" do
      port = start_trickler()

      {elapsed_ms, result} =
        time(fn -> RssFetcher.probe("http://127.0.0.1:#{port}/feed", @tiny_bounds) end)

      assert {:error, _} = result

      assert elapsed_ms < @must_return_within_ms,
             "receive phase ignored a 1s request_timeout: took #{elapsed_ms}ms"
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
        time(fn ->
          RssFetcher.fetch_and_parse("http://127.0.0.1:#{port}/feed.xml", @tiny_bounds)
        end)

      assert {:error, _} = result

      assert elapsed_ms < @must_return_within_ms,
             "receive phase ignored a 1s request_timeout: took #{elapsed_ms}ms"
    end
  end
end
