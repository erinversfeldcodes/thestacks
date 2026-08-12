defmodule Stacks.Books.HttpClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Stacks.Books.HttpClient

  @url "http://example.test/api"

  describe "map_error/2 with Finch >= 0.23 error structs" do
    test "HTTP/1 pool timeout (%Finch.TransportError{reason: :timeout}) maps to :timeout" do
      error = %Finch.TransportError{
        reason: :timeout,
        source: %Mint.TransportError{reason: :timeout}
      }

      log =
        capture_log(fn ->
          assert HttpClient.map_error(error, @url) == {:error, :timeout}
        end)

      assert log =~ "request timed out"
    end

    test "HTTP/2 pool timeout (%Finch.Error{reason: :timeout}) maps to :timeout" do
      log =
        capture_log(fn ->
          assert HttpClient.map_error(%Finch.Error{reason: :timeout}, @url) ==
                   {:error, :timeout}
        end)

      assert log =~ "request timed out"
    end

    test "%Finch.Error{reason: :request_timeout} maps to :timeout" do
      assert capture_log(fn ->
               assert HttpClient.map_error(%Finch.Error{reason: :request_timeout}, @url) ==
                        {:error, :timeout}
             end) =~ "request timed out"
    end

    test "non-timeout transport error maps to :transport_error" do
      error = %Finch.TransportError{
        reason: :econnrefused,
        source: %Mint.TransportError{reason: :econnrefused}
      }

      log =
        capture_log(fn ->
          assert HttpClient.map_error(error, @url) == {:error, :transport_error}
        end)

      assert log =~ "transport error"
    end

    test "HTTP protocol error falls through to :transport_error" do
      error = %Finch.HTTPError{reason: :invalid_status_line, module: Mint.HTTP1, source: nil}

      log =
        capture_log(fn ->
          assert HttpClient.map_error(error, @url) == {:error, :transport_error}
        end)

      assert log =~ "request failed"
    end

    test "unknown error term falls through to :transport_error" do
      log =
        capture_log(fn ->
          assert HttpClient.map_error(:some_future_error, @url) == {:error, :transport_error}
        end)

      assert log =~ "request failed"
    end
  end

  describe "get/1" do
    test "connection refused returns {:error, :transport_error}" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      capture_log(fn ->
        assert HttpClient.get("http://127.0.0.1:#{port}/") == {:error, :transport_error}
      end)
    end
  end
end
