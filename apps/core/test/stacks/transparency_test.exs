defmodule Stacks.TransparencyTest do
  @moduledoc """
    Tests for the public transparency data layer.

    Load-bearing invariants:
      * allowlist enforcement — only fixed, code-defined queries run; there is
        NO code path that runs an arbitrary / user-supplied PromQL string;
      * anonymisation — the payload is aggregates only (no per-user field,
        no de-anonymisable / linked-account dimension);
      * graceful degradation — with the Prometheus client/token absent the live
        section is `:unavailable`, never an error/leak, and durable is still served;
      * cache — a second call within TTL does not re-invoke the Prometheus client.
  """

  use Core.DataCase, async: false

  alias Stacks.Transparency
  alias Stacks.Transparency.{Cache, MockPrometheusClient}

  @allowed_entry_keys MapSet.new([:key, :label, :what, :how, :why, :unit, :value])

  setup do
    Cache.invalidate_all()
    MockPrometheusClient.reset()
    :ok
  end

  describe "allowlist enforcement" do
    test "a allowlisted signal returns the client's value unchanged" do
      MockPrometheusClient.put_response({:ok, 0.42})

      key = hd(Transparency.allowlist_keys())
      assert {:ok, 0.42} = Transparency.run_signal(key)
    end

    test "an un-allowlisted key cannot be run (no arbitrary/injected PromQL path)" do
      assert {:error, :not_allowlisted} = Transparency.run_signal(:definitely_not_a_signal)

      assert {:error, :not_allowlisted} =
               Transparency.run_signal(:"rate(secret_metric[1h]) or 1")
    end

    test "every allowlist entry is a fixed atom key mapped to a code-defined query" do
      keys = Transparency.allowlist_keys()
      refute Enum.empty?(keys)
      assert Enum.all?(keys, &is_atom/1)
    end
  end

  describe "app scoping (Fly org-wide Prometheus)" do
    setup do
      prev = Application.get_env(:core, :fly_metrics_app)
      Application.put_env(:core, :fly_metrics_app, "thestacks-core")
      on_exit(fn -> restore_env(:fly_metrics_app, prev) end)
      :ok
    end

    test "the query sent to the client is scoped to the serving app" do
      MockPrometheusClient.put_response({:ok, 1.0})

      key = hd(Transparency.allowlist_keys())
      assert {:ok, _} = Transparency.run_signal(key)

      sent = MockPrometheusClient.last_query()
      assert sent =~ ~s|app="thestacks-core"|
      refute sent =~ "$app"
    end

    test "every allowlisted query carries an app-scope matcher, so none can regress unscoped" do
      MockPrometheusClient.put_response({:ok, 1.0})

      for key <- Transparency.allowlist_keys() do
        assert {:ok, _} = Transparency.run_signal(key)
        sent = MockPrometheusClient.last_query()

        assert sent =~ ~r/stacks_[a-zA-Z0-9_]+\{[^}]*app="thestacks-core"/,
               "allowlist query for #{inspect(key)} is not app-scoped: #{sent}"
      end
    end
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: Application.put_env(:core, key, value)

  describe "metrics/0 — shape + teaching metadata" do
    test "returns live, durable, generated_at, cache_ttl" do
      MockPrometheusClient.put_response({:ok, 1.0})

      metrics = Transparency.metrics()

      assert Map.has_key?(metrics, :live)
      assert Map.has_key?(metrics, :durable)
      assert %DateTime{} = metrics.generated_at

      assert metrics.cache_ttl == 45
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

        assert entry.value == 3.5,
               "live entry #{inspect(entry.key)} did not carry the client's configured value"
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
               "entry exposed a non-allowlisted field: #{inspect(MapSet.difference(entry_keys, @allowed_entry_keys))}"
      end
    end

    test "the serialised payload contains no PII / linked-account markers" do
      MockPrometheusClient.put_response({:ok, 2.0})

      body = Transparency.metrics() |> Jason.encode!() |> String.downcase()

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

      assert Cache.get(:live_signals, 0) == :miss
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
