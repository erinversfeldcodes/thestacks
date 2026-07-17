defmodule Core.PromEx.MetricsPusherTest do
  use ExUnit.Case, async: false

  alias Core.PromEx.MetricsPusher

  describe "build_url/1" do
    test "appends the import path + app extra_label and trims a trailing slash" do
      url = MetricsPusher.build_url("http://vm.internal:8428/")
      assert String.starts_with?(url, "http://vm.internal:8428/api/v1/import/prometheus?")
      # `extra_label=app=<name>` — the `=` between app and name is URL-encoded (%3D).
      assert url =~ "extra_label=app%3D"
      refute url =~ "8428//api"
    end
  end

  describe "init/1 (fail-safe: disabled unless a target is set)" do
    setup do
      prev_url = Application.get_env(:core, :metrics_push_url)
      prev_int = Application.get_env(:core, :metrics_push_interval_ms)

      on_exit(fn ->
        restore(:metrics_push_url, prev_url)
        restore(:metrics_push_interval_ms, prev_int)
      end)

      :ok
    end

    test "returns :ignore when no push URL is configured" do
      Application.delete_env(:core, :metrics_push_url)
      assert MetricsPusher.init([]) == :ignore
    end

    test "returns :ignore for a blank push URL" do
      Application.put_env(:core, :metrics_push_url, "")
      assert MetricsPusher.init([]) == :ignore
    end

    test "starts, builds the URL and schedules a push when configured" do
      Application.put_env(:core, :metrics_push_url, "http://vm.internal:8428")
      Application.put_env(:core, :metrics_push_interval_ms, 40)

      assert {:ok, state} = MetricsPusher.init([])
      assert state.url =~ "/api/v1/import/prometheus?extra_label=app%3D"
      assert state.interval == 40
      # schedule/1 sent a :push to this process (we're standing in for the GenServer).
      assert_receive :push, 500
    end
  end

  defp restore(key, nil), do: Application.delete_env(:core, key)
  defp restore(key, value), do: Application.put_env(:core, key, value)
end
