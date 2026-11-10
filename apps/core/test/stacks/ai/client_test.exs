defmodule Stacks.AI.ClientTest do
  # ⚠️ DataCase rather than ExUnit.Case: the budget check this module drives
  # now reads a durable ledger instead of GenServer state, so these tests need
  # a sandboxed connection. Without one they fail on ownership, which looks
  # like a flake and is really a missing sandbox.
  use Core.DataCase, async: false

  alias Stacks.AI.Budget
  alias Stacks.AI.Client
  alias Stacks.AI.MockClient
  alias Stacks.AI.Spend
  alias Stacks.Costs

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

      Application.put_env(:core, :vision_service_url, "http://127.0.0.1:1")
      Application.put_env(:core, :vision_client, Stacks.AI.Client)
      :fuse.reset(:vision_fuse)

      on_exit(fn ->
        Application.put_env(:core, :vision_service_url, original_url)
        Application.put_env(:core, :vision_client, original_client)
        :fuse.reset(:vision_fuse)
      end)

      :ok
    end

    # ⛔ READ FROM THE LEDGER, NOT FROM A GenServer'S STRUCT. This asserted
    # `current_state().daily_total_cents` — a second copy of the spend that died
    # with the process and has now been deleted. The claim is the same and the
    # evidence is better: the charge is a row, so it is still there after the
    # thing that recorded it is gone.
    test "records modal cost even when the request errors" do
      assert Spend.spent(:modal, :daily) == 0

      assert {:error, _reason} = Client.call_vision("analyze", %{image: "test"})

      # ⛔ THIS ASSERTION USED TO ENCODE A UNIT CONFUSION AS A REQUIREMENT. It
      # read `Spend.spent(:modal, :daily) == cost_per_call` — a MICRO-cent
      # ledger total equal to a CENTS-denominated config value — and so it
      # passed while every Modal call charged 1 micro-cent instead of 1 cent,
      # leaving the daily 500¢ ceiling needing 50,000,000 calls to trip.
      #
      # ⚖️ The conversion is now the thing asserted, because that is the claim:
      # a call costing one cent must move a micro-cent ledger by 100,000.
      # ⛔ A THIRD COPY OF MODAL'S PRICE LIVED HERE, and it was stale. This read
      # `Application.get_env(..., 1)` — its own duplicate of a default that was
      # `1` in `Client` while `Costs` billed the public page at `3`. So three
      # artefacts named one price and two of them disagreed with the page.
      #
      # ⚖️ Read from the owner, `Costs.modal_budget_estimate_cents_per_call/0`,
      # which is now NAMED for what it is: a deliberately conservative BUDGET
      # estimate, not a price. As a price it was 18.9x the measured active cost
      # of an identification; as a ceiling input, over-charging is the safe
      # direction, so the figure is right here and was wrong on the cost page.
      # The page now prices inference from measured GPU seconds. ⚠️ Do not
      # reunify them without deciding which way each caller must err. This
      # assertion cannot drift from the number that is actually charged. A test
      # carrying its own copy of the value under test agrees with whichever copy
      # it holds and proves nothing about the other two.
      cost_cents =
        Application.get_env(
          :core,
          :modal_cost_per_call_cents,
          Costs.modal_budget_estimate_cents_per_call()
        )

      expected = cost_cents * 100_000

      assert Spend.spent(:modal, :daily) == expected,
             "a call costing #{cost_cents}c moved the micro-cent ledger by " <>
               "#{Spend.spent(:modal, :daily)}, not #{expected} — the unit the ledger " <>
               "stores and the unit this config value is written in have diverged"

      assert Spend.spent(:modal, :monthly) == expected
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

  describe "the tier label is bounded before it reaches the metrics store" do
    # ⛔ THIS GUARD HAD NO TEST THAT COULD FAIL UNTIL NOW. Its first test lived
    # in the PromEx suite, whose helper emits telemetry directly and so walked
    # straight past the bound — the assertion passed with `bounded_tier/1`
    # reduced to the identity function. A probe is the only reason that is
    # known.
    #
    # ⚖️ `tier` is the first label on the vision metrics that arrives as a
    # STRING OFF THE WIRE. `endpoint` and `status` are ours; a tier name comes
    # from a sidecar that may be deployed ahead of this build, so an unbounded
    # label here is a cardinality commitment to the metrics store that whoever
    # deploys the sidecar never agreed to make.
    test "a declared tier passes through unchanged" do
      assert Client.bounded_tier("ANALYSIS_TIER_BARCODE") == "ANALYSIS_TIER_BARCODE"
      assert Client.bounded_tier("ANALYSIS_TIER_VLM_EXTRACT") == "ANALYSIS_TIER_VLM_EXTRACT"
    end

    test "an undeclared tier collapses to other" do
      assert Client.bounded_tier("ANALYSIS_TIER_COVER_EMBEDDING") == "other"
      assert Client.bounded_tier("whatever the sidecar felt like sending") == "other"
      assert Client.bounded_tier("") == "other"
      assert Client.bounded_tier(nil) == "other"
    end

    # ⬛ ANTI-VACUITY, and it is the assertion the earlier version lacked: a
    # tier this build does NOT declare must come out DIFFERENT from what went
    # in. An identity function satisfies the first case above; only this one
    # distinguishes a bound from no bound.
    test "the collapse actually changes the value" do
      undeclared = "ANALYSIS_TIER_SOMETHING_THE_SIDECAR_SHIPPED_FIRST"

      assert Client.bounded_tier(undeclared) != undeclared,
             "an undeclared tier reached the label unchanged — the metrics store's cardinality " <>
               "is then set by whatever a separately deployed sidecar sends"
    end
  end

  describe "a barcode hit and a VLM inference are not the same cost" do
    # ⛔ THIS IS THE WHOLE POINT OF THE TIER FIELD, and it was unanswerable
    # before it. Every Modal call was charged a flat rate, so a CPU barcode
    # decode that never woke the GPU cost the same as a 7B VLM inference — and
    # "should a cover-embedding tier exist?" cannot be argued from a figure
    # that cannot tell those apart.
    test "a barcode tier adds no GPU surcharge" do
      assert Client.tier_surcharge_micro_cents("ANALYSIS_TIER_BARCODE") == 0
    end

    test "a VLM tier adds the GPU surcharge" do
      expected = Costs.modal_gpu_inference_surcharge_cents() * 100_000

      assert Client.tier_surcharge_micro_cents("ANALYSIS_TIER_VLM_EXTRACT") == expected
      assert Client.tier_surcharge_micro_cents("ANALYSIS_TIER_VLM_CLASSIFY") == expected
    end

    # ⬛ ANTI-VACUITY, and it is the assertion that matters: the two must
    # actually DIFFER. A surcharge function returning 0 for everything would
    # satisfy the first case, and one returning the same figure for everything
    # would satisfy the second — either way reinstating the flat rate this
    # change exists to remove.
    test "the two tiers are charged differently" do
      barcode = Client.tier_surcharge_micro_cents("ANALYSIS_TIER_BARCODE")
      vlm = Client.tier_surcharge_micro_cents("ANALYSIS_TIER_VLM_EXTRACT")

      assert barcode != vlm,
             "a barcode decode and a GPU inference are charged the same — the ledger cannot " <>
               "answer the question the vision redesign is decided on"
    end

    # ⛔ THE FIGURE IS A LITERAL, AND THAT IS THE POINT OF THIS CASE.
    #
    # The three cases above read `Costs.modal_gpu_inference_surcharge_cents()`
    # — the same source the code reads — so they prove the two tiers differ and
    # prove NOTHING about the unit. A test that derives its expectation through
    # the same path as the code agrees with the code whatever the code says,
    # which is exactly how this call site charged **1 micro-cent instead of 1
    # cent** for months while a test asserted it was correct.
    #
    # ⚖️ So this one spells the arithmetic out: the price is 3 cents, a cent is
    # 100,000 micro-cents, therefore a GPU tier's surcharge is 300,000. If
    # someone changes the price, this case fails and they must come and change
    # a number a person can read — which is the review this test exists to
    # force.
    test "a GPU tier's surcharge is 300_000 micro-cents, written out" do
      assert Costs.modal_gpu_inference_surcharge_cents() == 3,
             "the price changed; update the literal below deliberately rather than deriving it"

      assert Client.tier_surcharge_micro_cents("ANALYSIS_TIER_VLM_EXTRACT") == 300_000,
             "3 cents is 300,000 micro-cents — a mismatch here is the unit confusion that " <>
               "left the Modal ceiling needing 50,000,000 calls to trip"
    end

    # ⚠️ A tier this build has not been taught adds NOTHING rather than a
    # guess. Under-charging a new tier shows up as a ledger lagging the
    # invoice, which someone notices; billing for work we cannot describe does
    # not.
    test "an unknown tier adds no surcharge" do
      assert Client.tier_surcharge_micro_cents("ANALYSIS_TIER_SOMETHING_NEW") == 0
      assert Client.tier_surcharge_micro_cents(nil) == 0
    end
  end

  describe "the GPU cold-start count reaches telemetry from a real 200" do
    # ⛔ THE FIRST LINK OF THE IDLE-COST CHAIN HAD NO TEST THAT COULD FAIL.
    # `maybe_record_gpu_cold_start/1` is private and reachable only through
    # `make_vision_request/2`, and no test ever gave that function a 200 — the
    # transport-path tests point at a closed port on purpose. So deleting the
    # call, or changing the matched key, left the suite green and the public
    # idle-cost line permanently at "unavailable".
    #
    # ⚖️ A real Bandit server on a real port, because the thing under test is
    # what happens when a 200 with a body arrives. Stubbing the HTTP client
    # would fake away the parse, the dedup and the emit — which is the shape
    # that made an earlier test of this module vacuous.
    setup do
      original_url = Application.get_env(:core, :vision_service_url)
      original_client = Application.get_env(:core, :vision_client)
      test_pid = self()

      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__.StubVision, test_pid},
          port: 0,
          startup_log: false
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

      Application.put_env(:core, :vision_service_url, "http://127.0.0.1:#{port}")
      Application.put_env(:core, :vision_client, Stacks.AI.Client)
      :fuse.reset(:vision_fuse)

      handler = {__MODULE__, :cold_start_events, self()}

      :telemetry.attach(
        handler,
        [:stacks, :vision, :gpu_cold_start],
        fn _e, measurements, _meta, pid -> send(pid, {:cold_start, measurements}) end,
        self()
      )

      on_exit(fn ->
        :telemetry.detach(handler)
        Application.put_env(:core, :vision_service_url, original_url)
        Application.put_env(:core, :vision_client, original_client)
        :fuse.reset(:vision_fuse)
      end)

      :ok
    end

    test "two cold dispatches on different containers record two lifetimes" do
      __MODULE__.StubVision.respond(%{
        "classification" => "CLASSIFICATION_RESULT_BOOK",
        "tier" => "ANALYSIS_TIER_VLM_EXTRACT",
        "gpu_dispatches" => [
          %{"cold" => true, "container_id" => "one"},
          %{"cold" => true, "container_id" => "two"}
        ]
      })

      assert {:ok, _} = Client.call_vision("analyze", %{image: "test"})

      assert_receive {:cold_start, %{count: 2}}, 5_000
    end

    # ⬛ ANTI-VACUITY: the count must FOLLOW the response. A fixed `count: 1`
    # would satisfy the case above on its own, and an emit that fired
    # unconditionally would satisfy both.
    test "two cold dispatches on the SAME container record one lifetime" do
      __MODULE__.StubVision.respond(%{
        "classification" => "CLASSIFICATION_RESULT_BOOK",
        "tier" => "ANALYSIS_TIER_VLM_EXTRACT",
        "gpu_dispatches" => [
          %{"cold" => true, "container_id" => "same"},
          %{"cold" => true, "container_id" => "same"}
        ]
      })

      assert {:ok, _} = Client.call_vision("analyze", %{image: "test"})

      assert_receive {:cold_start, %{count: 1}}, 5_000
    end

    test "a barcode answer with no GPU dispatches records nothing" do
      __MODULE__.StubVision.respond(%{
        "classification" => "CLASSIFICATION_RESULT_BOOK",
        "tier" => "ANALYSIS_TIER_BARCODE",
        "gpu_dispatches" => []
      })

      assert {:ok, _} = Client.call_vision("analyze", %{image: "test"})

      refute_receive {:cold_start, _}, 200
    end

    test "a warm dispatch records nothing" do
      __MODULE__.StubVision.respond(%{
        "classification" => "CLASSIFICATION_RESULT_BOOK",
        "tier" => "ANALYSIS_TIER_VLM_CLASSIFY",
        "gpu_dispatches" => [%{"cold" => false, "container_id" => "warm"}]
      })

      assert {:ok, _} = Client.call_vision("analyze", %{image: "test"})

      refute_receive {:cold_start, _}, 200
    end
  end

  defmodule StubVision do
    @moduledoc false
    # A real HTTP endpoint, so the 200 branch of `make_vision_request/2` runs
    # for real: the body is parsed, the dispatch list de-duplicated and the
    # telemetry emitted by the code under test rather than by the test.
    import Plug.Conn

    def respond(body), do: :persistent_term.put({__MODULE__, :body}, body)

    def init(test_pid), do: test_pid

    def call(conn, _test_pid) do
      body = :persistent_term.get({__MODULE__, :body}, %{})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end
end
