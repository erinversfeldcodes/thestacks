defmodule Stacks.AI.BudgetTrackerTest do
  @moduledoc """
      That the ceiling is still there after the node that was counting is gone.

      ⛔ WHAT CHANGED, AND WHY THESE TESTS LOOK DIFFERENT. They used to drive the
      GenServer's internal protocol directly — `GenServer.call(pid,
      {:check_budget, …})` — which is not what production calls and not where the
      decision lives any more. `Stacks.AI.Client` calls
      `BudgetTracker.check_budget/1` and `record_cost/2`, so those are what is
      tested here.

      ⚠️ A test that drives the internal message instead of the public function
      can pass while the public function is broken or absent, which is the
      shape of a test guarding a copy of the thing it means to guard.
  """
  use Core.DataCase, async: false

  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.Spend

  setup do
    # The default limits, so the numbers below read against something stated.
    Application.put_env(:core, :daily_limit_cents, 500)
    Application.put_env(:core, :monthly_limit_cents, 5_000)

    on_exit(fn ->
      Application.delete_env(:core, :daily_limit_cents)
      Application.delete_env(:core, :monthly_limit_cents)
    end)

    :ok
  end

  describe "check_budget/1" do
    test "allows a provider that has spent nothing" do
      assert :ok == BudgetTracker.check_budget(:together)
    end

    test "allows a provider under its daily limit" do
      :ok = BudgetTracker.record_cost(:together, 100)

      assert :ok == BudgetTracker.check_budget(:together)
    end

    test "refuses a provider at its daily limit" do
      :ok = BudgetTracker.record_cost(:together, 600)

      assert {:error, :daily_limit_exceeded} == BudgetTracker.check_budget(:together)
    end

    test "refuses a provider at its monthly limit" do
      :ok = BudgetTracker.record_cost(:together, 6_000)

      assert {:error, :monthly_limit_exceeded} == BudgetTracker.check_budget(:together)
    end

    # ⛔ THE CASE THE PERSISTENCE EXISTS FOR, AND THE ONE NO VERSION OF THIS
    # SUITE COULD STATE BEFORE.
    #
    # The totals used to live in GenServer state, so a restarted process — a
    # redeployed or scaled-to-zero node — came back believing nothing had been
    # spent. The ceiling was restored by idling, invisibly, and the only way to
    # exceed a daily cap was to stay busy enough to stay alive.
    test "a restart does not restore the budget" do
      :ok = BudgetTracker.record_cost(:together, 600)
      assert {:error, :daily_limit_exceeded} == BudgetTracker.check_budget(:together)

      # Whatever process was holding a view of this is now gone.
      if pid = Process.whereis(BudgetTracker) do
        Process.exit(pid, :kill)
      end

      assert {:error, :daily_limit_exceeded} == BudgetTracker.check_budget(:together),
             "the budget came back after the process died — which is the defect: " <>
               "a ceiling restored by a restart is not a ceiling"
    end

    # ⚠️ The decision must not need the GenServer at all. If it did, a node
    # whose tracker had crashed would answer ":ok" to everything — failing OPEN
    # on the one check whose job is to refuse.
    test "the decision does not depend on the tracker process running" do
      :ok = BudgetTracker.record_cost(:together, 600)

      if pid = Process.whereis(BudgetTracker) do
        Process.exit(pid, :kill)
        refute Process.alive?(pid)
      end

      assert {:error, :daily_limit_exceeded} == BudgetTracker.check_budget(:together)
    end

    # ⚖️ The limits used to be GLOBAL totals, so one provider's spend refused
    # another provider's requests — which is not what a per-provider budget
    # means.
    test "one provider's spend does not refuse another's requests" do
      :ok = BudgetTracker.record_cost(:together, 600)

      assert {:error, :daily_limit_exceeded} == BudgetTracker.check_budget(:together)
      assert :ok == BudgetTracker.check_budget(:modal)
    end
  end

  describe "record_cost/2" do
    test "accumulates across calls" do
      :ok = BudgetTracker.record_cost(:together, 100)
      :ok = BudgetTracker.record_cost(:together, 200)

      assert Spend.spent(:together, :daily) == 300
    end

    test "meters each provider separately" do
      :ok = BudgetTracker.record_cost(:together, 100)
      :ok = BudgetTracker.record_cost(:modal, 200)

      assert Spend.spent(:together, :daily) == 100
      assert Spend.spent(:modal, :daily) == 200
    end

    # ⚠️ The ledger write happens in the CALLER's process, not in the
    # GenServer's — a `cast` is fire-and-forget, and the durable note of a
    # charge that has already been made should not depend on a mailbox.
    test "the charge is recorded even with no tracker process running" do
      if pid = Process.whereis(BudgetTracker) do
        Process.exit(pid, :kill)
      end

      assert :ok == BudgetTracker.record_cost(:together, 250)
      assert Spend.spent(:together, :daily) == 250
    end
  end

  describe "the spend gauge" do
    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:stacks, :budget, :spend],
        fn _event, measurements, metadata, _ ->
          send(parent, {:spend_gauge, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      :ok
    end

    # ⛔ THE GAUGE REPORTS THE LEDGER, NOT THE EVENT STREAM.
    #
    # The pre-existing spend series is a `sum` over `cost_recorded` events,
    # which accumulates what the application happened to emit. That is not what
    # refuses a request: a dropped event, a restart mid-charge or a retention
    # sweep moves one and not the other, and a dashboard showing the wrong one
    # says a provider has budget left when it does not.
    test "it carries the totals the decision was made from" do
      :ok = BudgetTracker.record_cost(:together, 120)

      assert :ok = BudgetTracker.check_budget(:together)

      assert_receive {:spend_gauge, %{daily_cents: 120, monthly_cents: 120}, %{provider: "other"}}
    end

    # ⬛ ANTI-VACUITY: a second charge must move the gauge. Without this, a
    # hardcoded zero measurement would satisfy the case above whenever nothing
    # had been spent.
    test "it moves when more is spent" do
      :ok = BudgetTracker.record_cost(:together, 120)
      assert :ok = BudgetTracker.check_budget(:together)
      assert_receive {:spend_gauge, %{daily_cents: 120}, _}

      :ok = BudgetTracker.record_cost(:together, 30)
      assert :ok = BudgetTracker.check_budget(:together)

      assert_receive {:spend_gauge, %{daily_cents: 150}, _},
                     100,
                     "the gauge did not follow the ledger — a gauge that does not move " <>
                       "is indistinguishable from a provider that is not spending"
    end

    # ⚠️ Emitted on a REFUSAL too. A gauge that stops updating at the ceiling
    # goes flat exactly when someone is looking at it to find out why calls are
    # being declined.
    test "it is emitted when the budget refuses" do
      :ok = BudgetTracker.record_cost(:together, 600)

      assert {:error, :daily_limit_exceeded} = BudgetTracker.check_budget(:together)

      assert_receive {:spend_gauge, %{daily_cents: 600}, _}
    end
  end
end
