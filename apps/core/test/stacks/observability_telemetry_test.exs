defmodule Stacks.ObservabilityTelemetryTest do
  @moduledoc """
    Tests for observability instrumentation added in.

    Verifies that telemetry events fire correctly for:
    - Vision client requests (start/stop/exception)
    - Fuse melt/blown events
    - BudgetTracker cost recording and limit exceeded
    - Costs context cost recording
  """

  use Core.DataCase, async: false

  alias Stacks.AI.BudgetTracker

  defp attach_telemetry(events) do
    test_pid = self()
    ref = make_ref()

    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "vision request telemetry" do
    test "emits start and stop events on successful request" do
      attach_telemetry([
        [:stacks, :vision, :request, :start],
        [:stacks, :vision, :request, :stop]
      ])

      :telemetry.execute(
        [:stacks, :vision, :request, :start],
        %{system_time: System.system_time()},
        %{endpoint: "extract_isbn"}
      )

      :telemetry.execute(
        [:stacks, :vision, :request, :stop],
        %{duration: 1_000_000},
        %{endpoint: "extract_isbn", status: 200}
      )

      assert_receive {:telemetry_event, [:stacks, :vision, :request, :start], %{system_time: _},
                      %{endpoint: "extract_isbn"}}

      assert_receive {:telemetry_event, [:stacks, :vision, :request, :stop],
                      %{duration: 1_000_000}, %{endpoint: "extract_isbn", status: 200}}
    end

    test "emits exception event on error" do
      attach_telemetry([[:stacks, :vision, :request, :exception]])

      :telemetry.execute(
        [:stacks, :vision, :request, :exception],
        %{duration: 500_000},
        %{endpoint: "is_book", kind: :error, reason: :timeout}
      )

      assert_receive {:telemetry_event, [:stacks, :vision, :request, :exception],
                      %{duration: 500_000},
                      %{endpoint: "is_book", kind: :error, reason: :timeout}}
    end
  end

  describe "fuse telemetry" do
    test "emits melt event" do
      attach_telemetry([[:stacks, :fuse, :melt]])

      :telemetry.execute([:stacks, :fuse, :melt], %{}, %{fuse_name: :vision_service})

      assert_receive {:telemetry_event, [:stacks, :fuse, :melt], %{},
                      %{fuse_name: :vision_service}}
    end

    test "emits blown event" do
      attach_telemetry([[:stacks, :fuse, :blown]])

      :telemetry.execute([:stacks, :fuse, :blown], %{}, %{fuse_name: :vision_service})

      assert_receive {:telemetry_event, [:stacks, :fuse, :blown], %{},
                      %{fuse_name: :vision_service}}
    end
  end

  describe "budget tracker telemetry" do
    setup do
      name = :"budget_tracker_#{System.unique_integer([:positive])}"
      {:ok, pid} = BudgetTracker.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{tracker: name}
    end

    test "emits cost_recorded event on record_cost", %{tracker: name} do
      attach_telemetry([[:stacks, :budget, :cost_recorded]])

      GenServer.cast(name, {:record_cost, :modal, 42})

      _ = GenServer.call(name, :current_state)

      assert_receive {:telemetry_event, [:stacks, :budget, :cost_recorded], %{amount_cents: 42},
                      %{provider: "modal"}}
    end

    test "emits limit_exceeded event when daily limit exceeded", %{tracker: name} do
      attach_telemetry([
        [:stacks, :budget, :cost_recorded],
        [:stacks, :budget, :limit_exceeded]
      ])

      GenServer.cast(name, {:record_cost, :modal, 600})
      _ = GenServer.call(name, :current_state)

      GenServer.call(name, {:check_budget, :modal})

      assert_receive {:telemetry_event, [:stacks, :budget, :limit_exceeded], %{},
                      %{provider: "modal", type: :daily}}
    end

    test "emits limit_exceeded event when monthly limit exceeded", %{tracker: name} do
      attach_telemetry([
        [:stacks, :budget, :cost_recorded],
        [:stacks, :budget, :limit_exceeded]
      ])

      GenServer.cast(name, {:record_cost, :modal, 6_000})
      _ = GenServer.call(name, :current_state)

      GenServer.call(name, {:check_budget, :modal})

      assert_receive {:telemetry_event, [:stacks, :budget, :limit_exceeded], %{},
                      %{provider: "modal", type: :monthly}}
    end
  end

  describe "costs context telemetry" do
    test "emits recorded event on upsert_cost" do
      attach_telemetry([[:stacks, :costs, :recorded]])

      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

      period_end = %{
        now
        | day: Calendar.ISO.days_in_month(now.year, now.month),
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      attrs = %{
        category: "compute",
        service: "fly-core-#{System.unique_integer([:positive])}",
        description: "Core app compute",
        amount_cents: 1200,
        currency: "USD",
        period_start: period_start,
        period_end: period_end
      }

      assert {:ok, _cost} = Stacks.Costs.upsert_cost(attrs)

      assert_receive {:telemetry_event, [:stacks, :costs, :recorded], %{amount_cents: 1200},
                      %{category: "compute", service: service}}
                     when is_binary(service)
    end
  end
end
