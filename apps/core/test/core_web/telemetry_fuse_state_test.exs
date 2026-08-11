defmodule CoreWeb.TelemetryFuseStateTest do
  @moduledoc """
    Tests for the periodic fuse-state gauge.

    `CoreWeb.Telemetry.poll_fuse_state/0` must walk every registered fuse
    (vision_fuse, together_ai_fuse, open_library_fuse, google_books_fuse,
    scraper_fuse) and emit `[:stacks,:fuse,:state]` with:

        measurements: %{state: 0 | 1}
        metadata:     %{fuse_name: atom}

    State mapping: healthy (`:ok`) → 1, blown → 0.

    The emitted series feeds the SLO gate's "fuse open count = 0" threshold.
  """

  use ExUnit.Case, async: false

  alias Stacks.CircuitBreakers

  @managed_fuses [
    :vision_fuse,
    :together_ai_fuse,
    :open_library_fuse,
    :google_books_fuse,
    :scraper_fuse
  ]

  defp attach_state_handler do
    test_pid = self()
    handler_id = "fuse-state-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:stacks, :fuse, :state],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:fuse_state, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp drain_state_messages do
    receive do
      {:fuse_state, _, _} -> drain_state_messages()
    after
      0 -> :ok
    end
  end

  defp collect_state_events(expected_count, timeout_ms \\ 1_000) do
    do_collect(expected_count, timeout_ms, [])
  end

  defp do_collect(0, _timeout, acc), do: Enum.reverse(acc)

  defp do_collect(n, timeout, acc) do
    receive do
      {:fuse_state, measurements, metadata} ->
        do_collect(n - 1, timeout, [{measurements, metadata} | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  setup do
    CircuitBreakers.install_all()
    Enum.each(@managed_fuses, &:fuse.reset/1)

    on_exit(fn -> Enum.each(@managed_fuses, &:fuse.reset/1) end)

    :ok
  end

  describe "poll_fuse_state/0" do
    test "emits one [:stacks, :fuse, :state] event per managed fuse" do
      attach_state_handler()
      drain_state_messages()

      CoreWeb.Telemetry.poll_fuse_state()

      events = collect_state_events(length(@managed_fuses), 1_000)

      seen_fuse_names =
        events
        |> Enum.map(fn {_m, metadata} -> metadata.fuse_name end)
        |> Enum.sort()

      assert seen_fuse_names == Enum.sort(@managed_fuses),
             "expected one state event per managed fuse, got: #{inspect(seen_fuse_names)}"
    end

    test "every event carries :fuse_name metadata and numeric :state measurement" do
      attach_state_handler()
      drain_state_messages()

      CoreWeb.Telemetry.poll_fuse_state()

      events = collect_state_events(length(@managed_fuses), 1_000)

      assert length(events) == length(@managed_fuses),
             "expected #{length(@managed_fuses)} events, got: #{length(events)}"

      Enum.each(events, fn {measurements, metadata} ->
        assert is_atom(metadata.fuse_name),
               "expected :fuse_name atom metadata, got: #{inspect(metadata)}"

        assert measurements.state in [0, 1],
               "expected :state to be 0 or 1, got: #{inspect(measurements)}"
      end)
    end
  end

  describe "poll_fuse_state/0 — state value mapping" do
    test "healthy fuse reports state=1" do
      attach_state_handler()
      drain_state_messages()

      :fuse.reset(:vision_fuse)
      assert :ok = :fuse.ask(:vision_fuse, :sync)

      CoreWeb.Telemetry.poll_fuse_state()

      events = collect_state_events(length(@managed_fuses), 1_000)

      vision_event =
        Enum.find(events, fn {_m, metadata} -> metadata.fuse_name == :vision_fuse end)

      assert vision_event, "no :vision_fuse event emitted, got: #{inspect(events)}"

      {measurements, _metadata} = vision_event

      assert measurements.state == 1,
             "expected healthy :vision_fuse to report state=1, got: #{inspect(measurements)}"
    end

    test "blown fuse reports state=0" do
      attach_state_handler()
      drain_state_messages()

      :fuse.remove(:scraper_fuse)
      :fuse.install(:scraper_fuse, {{:standard, 0, 60_000}, {:reset, 60_000}})
      :fuse.melt(:scraper_fuse)

      assert :blown = :fuse.ask(:scraper_fuse, :sync)

      CoreWeb.Telemetry.poll_fuse_state()

      events = collect_state_events(length(@managed_fuses), 1_000)

      scraper_event =
        Enum.find(events, fn {_m, metadata} -> metadata.fuse_name == :scraper_fuse end)

      assert scraper_event, "no :scraper_fuse event emitted, got: #{inspect(events)}"

      {measurements, _metadata} = scraper_event

      assert measurements.state == 0,
             "expected blown :scraper_fuse to report state=0, got: #{inspect(measurements)}"
    end
  end
end
