defmodule Stacks.AI.TogetherClientBudgetTest do
  @moduledoc """
      The budget ceiling on the Together completion PATH, exercised through the
      REAL client.

      Every other suite configures `Stacks.AI.MockTogetherClient`, whose
      `complete/2` returns a canned result -- so the ceiling that lives inside
      `TogetherClient.do_complete/2` is faked away and has no test that can fail.
      A meter is not a ceiling, and a ceiling nothing exercises is not a ceiling
      either. This suite swaps the real client back in, plants an over-budget
      ledger (the durable `Stacks.AI.Spend` row, not a mock), and proves the path
      REFUSES -- returning the budget error before the fuse is asked or any HTTP
      request is built. Deleting the `check_budget/1` guard from `do_complete/2`
      reds both tests.
  """
  use Core.DataCase, async: false

  alias Stacks.AI.{Budget, TogetherClient}

  setup do
    prev_client = Application.get_env(:core, :together_client)
    prev_budget = Application.get_env(:core, :ai_budget)

    Application.put_env(:core, :together_client, TogetherClient)
    Application.put_env(:core, :ai_budget, daily_limit_cents: 500, monthly_limit_cents: 5_000)

    on_exit(fn ->
      restore(:together_client, prev_client)
      restore(:ai_budget, prev_budget)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:core, key)
  defp restore(key, value), do: Application.put_env(:core, key, value)

  test "a day over the daily cap hard-stops the completion path before the fuse or any HTTP call" do
    # 600 cents today: over the 500-cent daily cap, under the 5000-cent monthly.
    :ok = Budget.record_cost(:together, 60_000_000)

    assert {:error, {:budget_exceeded, :daily_limit_exceeded}} =
             TogetherClient.complete("compare these two books")
  end

  test "a month over the monthly cap hard-stops the completion path" do
    # 6000 cents: over the 5000-cent monthly cap, which check_budget/1 tests first.
    :ok = Budget.record_cost(:together, 600_000_000)

    assert {:error, {:budget_exceeded, :monthly_limit_exceeded}} =
             TogetherClient.complete("compare these two books")
  end
end
