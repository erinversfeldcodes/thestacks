defmodule Stacks.DurationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Stacks.Duration

  doctest Stacks.Duration

  describe "to_seconds/1" do
    test "converts every unit the config keys actually use" do
      assert Duration.to_seconds({20, :second}) == 20
      assert Duration.to_seconds({30, :minute}) == 1_800
      assert Duration.to_seconds({8, :hour}) == 28_800
      assert Duration.to_seconds({7, :day}) == 604_800
      assert Duration.to_seconds({2, :week}) == 1_209_600
    end

    test "accepts the plural spellings config is also written in" do
      assert Duration.to_seconds({8, :hours}) == Duration.to_seconds({8, :hour})
      assert Duration.to_seconds({30, :minutes}) == Duration.to_seconds({30, :minute})
      assert Duration.to_seconds({7, :days}) == Duration.to_seconds({7, :day})
      assert Duration.to_seconds({2, :weeks}) == Duration.to_seconds({2, :week})
      assert Duration.to_seconds({20, :seconds}) == Duration.to_seconds({20, :second})
    end

    test "zero and negative counts pass through arithmetically" do
      assert Duration.to_seconds({0, :day}) == 0
      assert Duration.to_seconds({-1, :hour}) == -3_600
    end
  end

  describe "unknown units — the regression this module exists for" do
    @tag :regression
    test "a day is a day, not a second (Stacks.Accounts' private table stopped at :hour)" do
      assert Duration.to_seconds({1, :day}) == 86_400
      assert Duration.to_seconds({1, :week}) == 604_800
    end

    test "an unrecognised unit falls back to seconds rather than raising" do
      capture_log(fn ->
        assert Duration.to_seconds({5, :fortnight}) == 5
      end)
    end

    test "the fallback says so — a misconfiguration is visible, not silent" do
      log = capture_log(fn -> Duration.to_seconds({5, :fortnight}) end)

      assert log =~ "unknown duration unit :fortnight"
      assert log =~ "honouring it as seconds"
    end

    test "the fallback is counted, so it is alertable without reading logs" do
      handler = "duration-unknown-unit-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:stacks, :duration, :unknown_unit],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      capture_log(fn -> Duration.to_seconds({5, :fortnight}) end)

      assert_receive {:telemetry, [:stacks, :duration, :unknown_unit], %{count: 1},
                      %{unit: :fortnight}}
    end

    test "a known unit is neither logged nor counted" do
      handler = "duration-known-unit-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:stacks, :duration, :unknown_unit],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      log = capture_log(fn -> assert Duration.to_seconds({7, :day}) == 604_800 end)

      refute log =~ "unknown duration unit"
      refute_receive {:telemetry, [:stacks, :duration, :unknown_unit], _, _}, 50
    end
  end

  describe "the unit table lives in exactly one module" do
    test "no module outside Stacks.Duration defines its own unit table" do
      offenders =
        Path.wildcard(Path.join([__DIR__, "..", "..", "lib", "**", "*.ex"]))
        |> Enum.reject(&String.ends_with?(&1, "duration.ex"))
        |> Enum.filter(fn path ->
          path
          |> File.read!()
          |> String.match?(~r/def\w*\s+\w*unit_in_seconds/)
        end)
        |> Enum.map(&Path.relative_to(&1, Path.join([__DIR__, "..", ".."])))

      assert offenders == [],
             """
             These modules define their own `{n, unit}` → seconds table:

               #{Enum.join(offenders, "\n  ")}

             That is how Stacks.Accounts ended up honouring {1, :day} as one
             second. Call Stacks.Duration.to_seconds/1 instead.
             """
    end
  end
end
