defmodule Stacks.AI.ClientTest do
  use ExUnit.Case, async: true

  alias Stacks.AI.Client

  # Token format: "<integer_timestamp>.<64_hex_chars>"
  @token_format ~r/\A\d+\.[0-9a-f]{64}\z/

  defp extract_token(req) do
    {_, value} = Enum.find(req.headers, fn {k, _} -> k == "X-Internal-Token" end)
    value
  end

  describe "build_vision_request/2 — HMAC token format" do
    test "X-Internal-Token header is present and matches <timestamp>.<64 hex chars>" do
      req = Client.build_vision_request("/classify", %{image: "test"})
      token = extract_token(req)

      assert String.match?(token, @token_format),
             "token #{inspect(token)} did not match expected format"
    end

    test "timestamp in token is within 5 seconds of current time" do
      now = System.os_time(:second)
      req = Client.build_vision_request("/classify", %{image: "test"})
      [ts_str, _sig] = String.split(extract_token(req), ".", parts: 2)
      ts = String.to_integer(ts_str)
      assert abs(now - ts) <= 5, "timestamp #{ts} is not close to now #{now}"
    end

    test "different paths produce different signatures" do
      tok_classify = extract_token(Client.build_vision_request("/classify", %{}))
      tok_extract = extract_token(Client.build_vision_request("/extract", %{}))

      [_ts1, sig1] = String.split(tok_classify, ".", parts: 2)
      [_ts2, sig2] = String.split(tok_extract, ".", parts: 2)

      refute sig1 == sig2
    end

    test "successive calls each produce a structurally valid token" do
      tok1 = extract_token(Client.build_vision_request("/classify", %{}))
      tok2 = extract_token(Client.build_vision_request("/classify", %{}))

      assert String.match?(tok1, @token_format)
      assert String.match?(tok2, @token_format)
    end
  end

  describe "build_vision_request/2 — other headers" do
    test "includes content-type application/json" do
      req = Client.build_vision_request("/classify", %{image: "test"})
      ct = Enum.find(req.headers, fn {k, _} -> k == "content-type" end)
      assert ct == {"content-type", "application/json"}
    end
  end

  describe "build_vision_request/2 — cross-language HMAC compatibility" do
    # Verifies that the token produced satisfies the same algorithm as the
    # Python verify_hmac function:
    #   message = f"{timestamp_str}.{method}.{path}"
    #   expected_hex = hmac.new(secret.encode(), message.encode(), sha256).hexdigest()
    #   token == f"{timestamp_str}.{expected_hex}"
    #
    # We replicate the Python verification here in Elixir so this test runs
    # offline without the Python sidecar.

    test "token satisfies the Python verify_hmac algorithm" do
      secret = Application.fetch_env!(:core, :vision_hmac_secret)
      path = "/classify"

      req = Client.build_vision_request(path, %{})
      [ts_str, provided_hex] = String.split(extract_token(req), ".", parts: 2)

      message = "#{ts_str}.POST.#{path}"
      expected_hex = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)

      assert provided_hex == expected_hex,
             "signature mismatch: got #{provided_hex}, expected #{expected_hex}"
    end

    test "a token with a timestamp >60s in the past would be outside the replay window" do
      # The client generates tokens; the Python sidecar enforces the ±60s window.
      # This confirms that a stale token's timestamp arithmetic is detectable.
      secret = Application.fetch_env!(:core, :vision_hmac_secret)
      stale_ts = Integer.to_string(System.os_time(:second) - 61)
      message = "#{stale_ts}.POST./classify"
      sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
      stale_token = "#{stale_ts}.#{sig}"

      [ts_str, _] = String.split(stale_token, ".", parts: 2)
      staleness = System.os_time(:second) - String.to_integer(ts_str)
      assert staleness > 60
    end
  end
end
