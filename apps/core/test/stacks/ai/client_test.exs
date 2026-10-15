defmodule Stacks.AI.ClientTest do
  use ExUnit.Case, async: false

  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.Client
  alias Stacks.AI.MockClient

  @token_format ~r/\A\d+\.[0-9a-f]{64}\z/

  defp extract_token(req) do
    {_, value} = Enum.find(req.headers, fn {k, _} -> k == "X-Internal-Token" end)
    value
  end

  describe "build_vision_request/2 — HMAC token format" do
    test "X-Internal-Token header is present and matches <timestamp>.<64 hex chars>" do
      req = Client.build_vision_request("/analyze", %{image: "test"})
      token = extract_token(req)

      assert String.match?(token, @token_format),
             "token #{inspect(token)} did not match expected format"
    end

    test "timestamp in token is within 5 seconds of current time" do
      now = System.os_time(:second)
      req = Client.build_vision_request("/analyze", %{image: "test"})
      [ts_str, _sig] = String.split(extract_token(req), ".", parts: 2)
      ts = String.to_integer(ts_str)
      assert abs(now - ts) <= 5, "timestamp #{ts} is not close to now #{now}"
    end

    test "different paths produce different signatures" do
      # The path is part of the signed message, which is what stops a token
      # minted for one route being replayed against another.
      #
      # ⚠️ One real path and one that does not exist, deliberately. This signed
      # "/classify" and "/extract" until 2026-10-15; both are now deleted, and a
      # test that pins a property by naming two live routes has to be rewritten
      # every time the route set changes. A route that never existed cannot be
      # deleted out from under it.
      tok_real = extract_token(Client.build_vision_request("/analyze", %{}))

      # ⚠️ "/not-a-route" is DELIBERATELY NEVER SERVED. The assertion needs two
      # distinct path strings, not two live routes — a fictional one cannot be
      # deleted out from under the test the way "/classify" and "/extract" were.
      # Do not "fix" it to a real endpoint.
      tok_other = extract_token(Client.build_vision_request("/not-a-route", %{}))

      [_ts1, sig1] = String.split(tok_real, ".", parts: 2)
      [_ts2, sig2] = String.split(tok_other, ".", parts: 2)

      refute sig1 == sig2
    end

    test "successive calls each produce a structurally valid token" do
      tok1 = extract_token(Client.build_vision_request("/analyze", %{}))
      tok2 = extract_token(Client.build_vision_request("/analyze", %{}))

      assert String.match?(tok1, @token_format)
      assert String.match?(tok2, @token_format)
    end
  end

  describe "build_vision_request/2 — other headers" do
    test "includes content-type application/json" do
      req = Client.build_vision_request("/analyze", %{image: "test"})
      ct = Enum.find(req.headers, fn {k, _} -> k == "content-type" end)
      assert ct == {"content-type", "application/json"}
    end
  end

  describe "endpoint_path/1 — path mapping" do
    # ⚠️ Two tests were removed from here, not just re-pointed. They read
    #
    #     req = Client.build_vision_request("/classify", %{})
    #     assert req.path == "/classify"
    #
    # which passes a literal path in and asserts it comes back out:
    # `build_vision_request/2` takes the path as an argument, so neither test
    # ever reached `endpoint_path/1`. They were tautologies wearing the name of
    # the function they did not exercise, and one of them named an endpoint that
    # no longer exists.
    #
    # The mapping is only reachable through `call_vision/2` -> `make_vision_request/2`,
    # and only against the REAL client — the mock short-circuits before it. So
    # the observable worth asserting is the one below: an unrecognised operation
    # fails loudly instead of being silently sent somewhere.
    test "an unknown operation raises rather than resolving to a path" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, Stacks.AI.Client)

        assert_raise ArgumentError, ~r/unknown vision endpoint/, fn ->
          Client.call_vision("not_an_endpoint", %{image: "test"})
        end
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "call_vision dispatches through mock without crashing for every live operation" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, Stacks.AI.MockClient)

        for endpoint <- ["is_book", "analyze"] do
          result = Client.call_vision(endpoint, %{image: "test"})
          assert {:ok, _} = result
        end
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "build_vision_request/2 — cross-language HMAC compatibility" do
    test "token satisfies the Python verify_hmac algorithm" do
      secret = Application.fetch_env!(:core, :vision_hmac_secret)
      path = "/analyze"

      req = Client.build_vision_request(path, %{})
      [ts_str, provided_hex] = String.split(extract_token(req), ".", parts: 2)

      message = "#{ts_str}.POST.#{path}"
      expected_hex = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)

      assert provided_hex == expected_hex,
             "signature mismatch: got #{provided_hex}, expected #{expected_hex}"
    end

    test "a token with a timestamp >60s in the past would be outside the replay window" do
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

  describe "make_vision_request/2 — the real transport path" do
    setup do
      original_url = Application.get_env(:core, :vision_service_url)
      original_client = Application.get_env(:core, :vision_client)
      original_state = :sys.get_state(BudgetTracker)

      Application.put_env(:core, :vision_service_url, "http://127.0.0.1:1")
      Application.put_env(:core, :vision_client, Stacks.AI.Client)
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
      assert BudgetTracker.current_state().daily_total_cents == 0

      result = Client.call_vision("analyze", %{image: "test"})
      assert {:error, _reason} = result

      state = BudgetTracker.current_state()
      cost_per_call = Application.get_env(:core, :modal_cost_per_call_cents, 1)
      assert state.daily_total_cents == cost_per_call
      assert state.monthly_total_cents == cost_per_call
      assert state.providers["modal"] == cost_per_call
    end

    test "the :exception event carries a bounded reason_class, not just the raw reason" do
      handler = {__MODULE__, :exception_metadata, self()}

      :telemetry.attach(
        handler,
        [:stacks, :vision, :request, :exception],
        fn _event, measurements, metadata, pid ->
          send(pid, {:vision_exception, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, _} = Client.call_vision("analyze", %{image: "test"})

      assert_receive {:vision_exception, _measurements, metadata}, 5_000

      assert Map.has_key?(metadata, :reason_class),
             "the :exception emit site must carry :reason_class — the counter tags on it, and " <>
               "a missing tag exports as an empty label rather than failing. Metadata: " <>
               inspect(Map.keys(metadata))

      assert metadata.reason_class in [:timeout, :closed, :unreachable, :protocol, :other],
             "reason_class must stay inside the closed set that makes it safe as a metric " <>
               "label; got #{inspect(metadata.reason_class)}"

      assert metadata.reason_class == :unreachable,
             "port 1 refuses, so Finch surfaces econnrefused and the classifier should say " <>
               ":unreachable; got #{inspect(metadata.reason_class)} from #{inspect(metadata.reason)}"
    end
  end
end
