defmodule Stacks.AI.BudgetTrackerTest do
  use ExUnit.Case, async: false

  alias Stacks.AI.BudgetTracker

  setup do
    name = :"budget_tracker_#{System.unique_integer()}"
    {:ok, pid} = BudgetTracker.start_link(name: name)
    %{pid: pid, name: name}
  end

  describe "check_budget/1" do
    test "returns :ok when no costs recorded", %{pid: pid} do
      assert :ok == GenServer.call(pid, {:check_budget, :openai})
    end

    test "returns :ok when under daily limit", %{pid: pid} do
      GenServer.cast(pid, {:record_cost, :openai, 100})
      assert :ok == GenServer.call(pid, {:check_budget, :openai})
    end

    test "returns daily_limit_exceeded when over daily limit", %{pid: pid} do
      # Default daily limit is 500 cents ($5)
      GenServer.cast(pid, {:record_cost, :openai, 600})
      assert {:error, :daily_limit_exceeded} == GenServer.call(pid, {:check_budget, :openai})
    end

    test "returns monthly_limit_exceeded when over monthly limit", %{pid: pid} do
      # Default monthly limit is 5000 cents ($50)
      GenServer.cast(pid, {:record_cost, :openai, 6_000})
      assert {:error, :monthly_limit_exceeded} == GenServer.call(pid, {:check_budget, :openai})
    end
  end

  describe "record_cost/2" do
    test "accumulates costs across multiple calls", %{pid: pid} do
      GenServer.cast(pid, {:record_cost, :openai, 100})
      GenServer.cast(pid, {:record_cost, :openai, 200})

      state = GenServer.call(pid, :current_state)
      assert state.daily_total_cents == 300
      assert state.monthly_total_cents == 300
    end

    test "tracks costs per provider", %{pid: pid} do
      GenServer.cast(pid, {:record_cost, :openai, 100})
      GenServer.cast(pid, {:record_cost, :anthropic, 200})

      state = GenServer.call(pid, :current_state)
      assert state.providers["openai"] == 100
      assert state.providers["anthropic"] == 200
    end
  end

  describe "current_state/0" do
    test "returns initial zeroed state", %{pid: pid} do
      state = GenServer.call(pid, :current_state)
      assert state.daily_total_cents == 0
      assert state.monthly_total_cents == 0
      assert state.providers == %{}
    end
  end
end
