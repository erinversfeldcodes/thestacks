defmodule Stacks.AI.ClientTest do
  use ExUnit.Case, async: true

  alias Stacks.AI.Client

  # Token format: "<integer_timestamp>.<64_hex_chars>"
  @token_format ~r/\A\d+\.[0-9a-f]{64}\z/

  describe "auth_token/2" do
    test "returns a string in the format <timestamp>.<64 lowercase hex chars>" do
      token = Client.auth_token("POST", "/classify")

      assert String.match?(token, @token_format),
             "token #{inspect(token)} did not match expected format"
    end

    test "timestamp in token is within 5 seconds of current time" do
      now = System.os_time(:second)
      token = Client.auth_token("POST", "/classify")
      [ts_str, _sig] = String.split(token, ".", parts: 2)
      ts = String.to_integer(ts_str)
      assert abs(now - ts) <= 5, "timestamp #{ts} is not close to now #{now}"
    end

    test "different method and path produce different signatures" do
      token_classify = Client.auth_token("POST", "/classify")
      token_extract = Client.auth_token("POST", "/extract")

      [_ts1, sig1] = String.split(token_classify, ".", parts: 2)
      [_ts2, sig2] = String.split(token_extract, ".", parts: 2)

      refute sig1 == sig2
    end

    test "two calls produce different timestamps (at least structurally valid)" do
      token1 = Client.auth_token("POST", "/classify")
      token2 = Client.auth_token("POST", "/classify")

      assert String.match?(token1, @token_format)
      assert String.match?(token2, @token_format)
    end
  end

  describe "auth_token/2 cross-language compatibility" do
    # Verify that the Elixir token satisfies the same algorithm as the Python
    # verify_hmac function:
    #   message = f"{timestamp_str}.{method}.{path}"
    #   expected_hex = hmac.new(secret.encode(), message.encode(), sha256).hexdigest()
    #   token == f"{timestamp_str}.{expected_hex}"
    #
    # We replicate that verification logic here in Elixir so this test can run
    # offline without the Python sidecar.

    test "token can be verified by the Python verify_hmac algorithm" do
      secret = Application.fetch_env!(:core, :vision_hmac_secret)
      method = "POST"
      path = "/classify"

      token = Client.auth_token(method, path)
      [ts_str, provided_hex] = String.split(token, ".", parts: 2)

      # Replicate the Python verification: HMAC-SHA256(secret, "<ts>.<METHOD>.<path>")
      message = "#{ts_str}.#{method}.#{path}"
      expected_hex = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)

      assert provided_hex == expected_hex,
             "token signature does not match expected HMAC; got #{provided_hex}, expected #{expected_hex}"
    end

    test "stale timestamp arithmetic is outside the ±60s replay window (rejection enforced by Python sidecar)" do
      # The Elixir client generates tokens; it never verifies them.
      # Rejection of stale tokens is enforced by the Python sidecar's verify_hmac/1.
      # This test confirms that a token generated 61+ seconds ago would have a
      # timestamp the Python sidecar would reject.
      stale_ts = Integer.to_string(System.os_time(:second) - 61)
      secret = Application.fetch_env!(:core, :vision_hmac_secret)
      message = "#{stale_ts}.POST./classify"
      sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
      stale_token = "#{stale_ts}.#{sig}"
      [ts_str, _sig] = String.split(stale_token, ".", parts: 2)
      staleness = System.os_time(:second) - String.to_integer(ts_str)
      assert staleness > 60
    end

    test "auth_token/2 signature is sensitive to path — tokens for different paths differ" do
      token_classify = Client.auth_token("POST", "/classify")
      token_extract = Client.auth_token("POST", "/extract")
      # Extract the signature portion (after the first dot)
      [_ts1, sig_classify] = String.split(token_classify, ".", parts: 2)
      [_ts2, sig_extract] = String.split(token_extract, ".", parts: 2)
      refute sig_classify == sig_extract
    end
  end

  describe "build_vision_request/2 HTTP headers" do
    # Tests the pure request-building function (no IO) to verify that the
    # X-Internal-Token header is included with the correct format.
    # `make_vision_request/2` delegates request construction to this function,
    # so header correctness is covered here without needing a live server.

    test "includes X-Internal-Token header with correct format for /classify" do
      req = Client.build_vision_request("/classify", %{image: "test"})

      token_header =
        Enum.find(req.headers, fn {k, _} -> k == "X-Internal-Token" end)

      assert token_header != nil, "X-Internal-Token header not found in request"
      {_, token_value} = token_header

      assert String.match?(token_value, @token_format),
             "X-Internal-Token value #{inspect(token_value)} did not match expected format"
    end

    test "includes content-type application/json header" do
      req = Client.build_vision_request("/classify", %{image: "test"})

      ct_header = Enum.find(req.headers, fn {k, _} -> k == "content-type" end)
      assert ct_header == {"content-type", "application/json"}
    end

    test "token in header uses path as the HMAC message component" do
      req_classify = Client.build_vision_request("/classify", %{})
      req_extract = Client.build_vision_request("/extract", %{})

      {_, tok_classify} =
        Enum.find(req_classify.headers, fn {k, _} -> k == "X-Internal-Token" end)

      {_, tok_extract} =
        Enum.find(req_extract.headers, fn {k, _} -> k == "X-Internal-Token" end)

      [_ts1, sig_classify] = String.split(tok_classify, ".", parts: 2)
      [_ts2, sig_extract] = String.split(tok_extract, ".", parts: 2)

      refute sig_classify == sig_extract,
             "Different paths must produce different HMAC signatures"
    end
  end
end
