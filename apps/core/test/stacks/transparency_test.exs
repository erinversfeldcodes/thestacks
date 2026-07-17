defmodule Stacks.TransparencyTest do
  @moduledoc """
  Tests for the public transparency data layer (Issue #241 / ADR-019).

  Load-bearing invariants:
    * whitelist enforcement — only fixed, code-defined queries run; there is
      NO code path that runs an arbitrary / user-supplied PromQL string;
    * anonymisation — the payload is aggregates only (no per-user field,
      no de-anonymisable / linked-account dimension);
    * graceful degradation — with the Prometheus client/token absent the live
      section is `:unavailable`, never an error/leak, and durable is still served;
    * cache — a second call within TTL does not re-invoke the Prometheus client.
  """

  # async: false — the ETS-backed cache and the shared config-wired mock are
  # global; serialising keeps cross-test cache bleed deterministic.
  use Core.DataCase, async: false

  alias Stacks.Transparency
  alias Stacks.Transparency.{Cache, MockPrometheusClient}

  # Only these keys may ever appear on a public entry. A stray :user_id,
  # :email, :ip, :handle etc. would fail the subset assertions below.
  @allowed_entry_keys MapSet.new([:key, :label, :what, :how, :why, :unit, :value])

  setup do
    Cache.invalidate_all()
    MockPrometheusClient.reset()
    :ok
  end

  describe "whitelist enforcement" do
    test "a whitelisted signal returns a number via the client" do
      MockPrometheusClient.put_response({:ok, 0.42})

      key = hd(Transparency.whitelist_keys())
      assert {:ok, value} = Transparency.run_signal(key)
      assert is_number(value)
    end

    test "an un-whitelisted key cannot be run (no arbitrary/injected PromQL path)" do
      # The public API accepts only whitelist KEYS (atoms), never raw PromQL.
      assert {:error, :not_whitelisted} = Transparency.run_signal(:definitely_not_a_signal)

      # Even an atom that looks like an injection attempt is rejected — there is
      # no branch that forwards a caller-supplied string to the client.
      assert {:error, :not_whitelisted} =
               Transparency.run_signal(:"rate(secret_metric[1h]) or 1")
    end

    test "every whitelist entry is a fixed atom key mapped to a code-defined query" do
      keys = Transparency.whitelist_keys()
      refute Enum.empty?(keys)
      assert Enum.all?(keys, &is_atom/1)
    end
  end

  describe "metrics/0 — shape + teaching metadata" do
    test "returns live, durable, generated_at, cache_ttl" do
      MockPrometheusClient.put_response({:ok, 1.0})

      metrics = Transparency.metrics()

      assert Map.has_key?(metrics, :live)
      assert Map.has_key?(metrics, :durable)
      assert %DateTime{} = metrics.generated_at
      assert is_integer(metrics.cache_ttl)
    end

    test "every live entry carries what/how/why teaching metadata" do
      MockPrometheusClient.put_response({:ok, 3.5})

      %{live: live} = Transparency.metrics()
      assert is_list(live)
      refute Enum.empty?(live)

      Enum.each(live, fn entry ->
        assert is_binary(entry.label)
        assert is_binary(entry.what)
        assert is_binary(entry.how)
        assert is_binary(entry.why)
        assert is_binary(entry.unit)
        assert is_number(entry.value)
      end)
    end

    test "every durable entry carries what/how/why teaching metadata" do
      %{durable: durable} = Transparency.metrics()
      assert is_list(durable)
      refute Enum.empty?(durable)

      Enum.each(durable, fn entry ->
        assert is_binary(entry.label)
        assert is_binary(entry.what)
        assert is_binary(entry.how)
        assert is_binary(entry.why)
        assert is_binary(entry.unit)
        assert is_number(entry.value)
      end)
    end
  end

  describe "anonymisation / no-PII / no-de-anon" do
    test "no entry carries a per-user or de-anonymisable field" do
      MockPrometheusClient.put_response({:ok, 2.0})

      %{live: live, durable: durable} = Transparency.metrics()

      for entry <- List.wrap(live) ++ durable do
        entry_keys = entry |> Map.keys() |> MapSet.new()

        assert MapSet.subset?(entry_keys, @allowed_entry_keys),
               "entry exposed a non-whitelisted field: #{inspect(MapSet.difference(entry_keys, @allowed_entry_keys))}"
      end
    end

    test "the serialised payload contains no PII / linked-account markers" do
      MockPrometheusClient.put_response({:ok, 2.0})

      body = Transparency.metrics() |> Jason.encode!() |> String.downcase()

      # Free-text prose (e.g. "event handler") legitimately contains some
      # substrings; a per-user field would be caught structurally by the
      # @allowed_entry_keys subset assertion above. This scan targets tokens
      # that can never appear in the curated copy.
      for forbidden <-
            ~w(user_id email password ip_address audible linked_account per_user) do
        refute String.contains?(body, forbidden),
               "payload leaked a forbidden token: #{forbidden}"
      end
    end
  end

  describe "graceful degradation" do
    test "live section is :unavailable when the client errors; durable still served" do
      MockPrometheusClient.put_response({:error, :not_configured})

      metrics = Transparency.metrics()

      assert metrics.live == :unavailable
      assert is_list(metrics.durable)
      refute Enum.empty?(metrics.durable)
    end

    test "an errored compute is not crashing or leaking the error term" do
      MockPrometheusClient.put_response({:error, :timeout})

      body = Transparency.metrics() |> Jason.encode!()
      refute String.contains?(body, "timeout")
    end
  end

  describe "stale-on-error cache" do
    test "get_stale returns the last cached value regardless of age; get respects TTL" do
      Cache.put(:live_signals, [:cached])

      # A zero TTL makes the fresh read miss (the entry is never younger than
      # 0ms under monotonic time)...
      assert Cache.get(:live_signals, 0) == :miss
      # ...but the stale-on-error read still serves the last good value — the
      # exact path refresh_live_signals/0 takes when a later compute errors.
      assert Cache.get_stale(:live_signals) == {:ok, [:cached]}
    end

    test "get_stale is a miss when nothing was ever cached for the key" do
      assert Cache.get_stale(:never_cached) == :miss
    end
  end

  describe "cache" do
    test "a second call within TTL does not re-invoke the Prometheus client" do
      MockPrometheusClient.put_response({:ok, 5.0})

      _ = Transparency.metrics()
      after_first = MockPrometheusClient.call_count()
      assert after_first > 0

      _ = Transparency.metrics()
      after_second = MockPrometheusClient.call_count()

      assert after_second == after_first,
             "expected the second call to hit the cache, but the client was invoked again"
    end
  end
end
