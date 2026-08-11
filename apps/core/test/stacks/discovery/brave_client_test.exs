defmodule Stacks.Discovery.BraveClientTest do
  use Core.DataCase, async: true

  alias Stacks.Discovery.BraveClient

  describe "BraveClient.increment_daily_counter/0 — the daily budget counter" do
    setup do
      :persistent_term.erase({BraveClient, :daily_counter})
      on_exit(fn -> :persistent_term.erase({BraveClient, :daily_counter}) end)
      :ok
    end

    test "does not crash on the first call in a fresh node" do
      assert BraveClient.increment_daily_counter() == :ok

      assert {_date, counter} =
               :persistent_term.get({BraveClient, :daily_counter}),
             "the first call must CREATE the counter, not assume one exists"

      assert :counters.get(counter, 1) == 1
    end

    test "counts successive calls in the same day" do
      for _ <- 1..3, do: BraveClient.increment_daily_counter()
      {_date, counter} = :persistent_term.get({BraveClient, :daily_counter})
      assert :counters.get(counter, 1) == 3
    end

    test "starts a new count when the stored date is not today" do
      stale = :counters.new(1, [:atomics])
      :counters.add(stale, 1, 199)
      yesterday = Date.add(Date.utc_today(), -1)
      :persistent_term.put({BraveClient, :daily_counter}, {yesterday, stale})

      assert BraveClient.increment_daily_counter() == :ok

      {date, counter} = :persistent_term.get({BraveClient, :daily_counter})
      assert date == Date.utc_today()

      assert :counters.get(counter, 1) == 1,
             "yesterday's 199 calls were carried into today's budget"
    end
  end
end
