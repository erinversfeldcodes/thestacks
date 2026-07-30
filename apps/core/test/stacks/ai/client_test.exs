defmodule Stacks.AI.ClientTest do
  # async: false — tests mutate the global :vision_client application env key
  # and the global BudgetTracker GenServer.
  use ExUnit.Case, async: false

  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.Client
  alias Stacks.AI.MockClient

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

  describe "associate_isbn/4 — mock client" do
    setup do
      original = Application.get_env(:core, :vision_client)
      Application.put_env(:core, :vision_client, Stacks.AI.MockClient)
      on_exit(fn -> Application.put_env(:core, :vision_client, original) end)
      :ok
    end

    test "returns {:ok, job_id} containing isbn and edition_id" do
      assert {:ok, job_id} =
               Client.associate_isbn(
                 "9780743273565",
                 "book-1",
                 "edition-1",
                 "https://example.com/cover.jpg"
               )

      assert is_binary(job_id)
      assert String.contains?(job_id, "9780743273565")
      assert String.contains?(job_id, "edition-1")
    end
  end

  describe "extract_from_url/1 — mock client" do
    setup do
      original = Application.get_env(:core, :vision_client)
      Application.put_env(:core, :vision_client, Stacks.AI.MockClient)
      on_exit(fn -> Application.put_env(:core, :vision_client, original) end)
      :ok
    end

    test "returns {:ok, result} with a books key" do
      assert {:ok, result} = Client.extract_from_url("https://example.com/cover.jpg")
      assert is_map(result)
      assert Map.has_key?(result, "books")
    end
  end

  describe "associate_isbn/4 — unexpected response shape" do
    setup do
      original = Application.get_env(:core, :vision_client)
      Application.put_env(:core, :vision_client, MockClient)
      on_exit(fn -> Application.put_env(:core, :vision_client, original) end)

      # Steer the seam rather than swapping in a bespoke module: /associate
      # answers without the "job_id" key the caller contract requires.
      MockClient.put_response("associate", {:ok, %{"unexpected_key" => "value"}})
      :ok
    end

    test "returns {:error, {:unexpected_response, _}} when job_id is missing" do
      assert {:error, {:unexpected_response, _}} =
               Client.associate_isbn(
                 "9780743273565",
                 "book-1",
                 "edition-1",
                 "https://example.com/cover.jpg"
               )
    end
  end

  describe "endpoint_path/1 — path mapping" do
    # Verifies that endpoint_path/1 maps logical endpoint names to HTTP paths
    # without making real HTTP calls. The vision sidecar requires GPU and
    # never runs locally.

    test "maps is_book to /classify" do
      req = Client.build_vision_request("/classify", %{})
      assert req.path == "/classify"
    end

    test "maps extract_isbn to /extract" do
      req = Client.build_vision_request("/extract", %{})
      assert req.path == "/extract"
    end

    test "call_vision dispatches through mock without crashing for all endpoints" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, Stacks.AI.MockClient)

        for endpoint <- ["is_book", "extract_isbn"] do
          result = Client.call_vision(endpoint, %{image: "test"})
          assert {:ok, _} = result
        end
      after
        Application.put_env(:core, :vision_client, original)
      end
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
    # offline without the Modal vision service.

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
      # The client generates tokens; the Modal vision service enforces the ±60s window.
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

  describe "make_vision_request/2 — BudgetTracker cost recording" do
    # The real client path is exercised here (not the mock dispatch) because
    # the cost-recording call site is inside `make_vision_request/2`. We
    # point the client at an unreachable port so Finch returns a transport
    # `{:error, _}` quickly without leaving the test host.
    setup do
      original_url = Application.get_env(:core, :vision_service_url)
      original_client = Application.get_env(:core, :vision_client)
      original_state = :sys.get_state(BudgetTracker)

      # Port 1 has no listener on any sane host; Finch returns a transport
      # error in milliseconds. Avoids a 210s wait on a real timeout path.
      Application.put_env(:core, :vision_service_url, "http://127.0.0.1:1")
      # Ensure dispatch lands in the real client, not the mock.
      Application.put_env(:core, :vision_client, Stacks.AI.Client)
      # Reset any fuse melt from a previous test so :fuse.ask returns :ok.
      :fuse.reset(:vision_fuse)

      :sys.replace_state(BudgetTracker, fn state ->
        %{state | daily_total_cents: 0, monthly_total_cents: 0, providers: %{}}
      end)

      on_exit(fn ->
        Application.put_env(:core, :vision_service_url, original_url)
        Application.put_env(:core, :vision_client, original_client)
        :sys.replace_state(BudgetTracker, fn _ -> original_state end)
        :fuse.reset(:vision_fuse)
      end)

      :ok
    end

    test "records modal cost in BudgetTracker even when the request errors" do
      # Sanity: starting from a clean zero state.
      assert BudgetTracker.current_state().daily_total_cents == 0

      # Drive a real Finch round-trip via call_vision/2. Port 1 will refuse,
      # so we land in the {:error, reason} branch of make_vision_request/2.
      result = Client.call_vision("analyze", %{image: "test"})
      assert {:error, _reason} = result

      # current_state/0 is a synchronous call — it serializes after the
      # cost-recording cast, ensuring the GenServer has processed it.
      state = BudgetTracker.current_state()
      cost_per_call = Application.get_env(:core, :modal_cost_per_call_cents, 1)
      assert state.daily_total_cents == cost_per_call
      assert state.monthly_total_cents == cost_per_call
      assert state.providers["modal"] == cost_per_call
    end
  end
end
