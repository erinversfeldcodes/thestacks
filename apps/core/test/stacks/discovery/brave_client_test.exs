defmodule Stacks.Discovery.BraveClientTest do
  use Core.DataCase, async: true

  alias Stacks.Discovery.BraveClient
  alias Stacks.Discovery.MockBraveClient

  describe "MockBraveClient.search/2" do
    test "returns empty list when no response is registered" do
      assert {:ok, []} = MockBraveClient.search("test query")
    end

    test "returns registered response" do
      results = [
        %{title: "Author Blog", url: "https://author.com", description: "An author's blog"}
      ]

      MockBraveClient.put_response({:ok, results})
      assert {:ok, ^results} = MockBraveClient.search("test query")
    end

    test "returns error when error response is registered" do
      MockBraveClient.put_response({:error, :rate_limited})
      assert {:error, :rate_limited} = MockBraveClient.search("test query")
    end

    test "clear removes registered response" do
      MockBraveClient.put_response(
        {:ok, [%{title: "Test", url: "https://test.com", description: ""}]}
      )

      MockBraveClient.clear()
      assert {:ok, []} = MockBraveClient.search("test query")
    end
  end

  describe "BraveClient.increment_daily_counter/0 — the daily budget counter" do
    setup do
      # A fresh node has NO persistent term for the counter. That is the state the bug lived in,
      # so every test here starts from it explicitly rather than inheriting whatever a previous
      # test left behind.
      :persistent_term.erase({BraveClient, :daily_counter})
      on_exit(fn -> :persistent_term.erase({BraveClient, :daily_counter}) end)
      :ok
    end

    test "does not crash on the first call in a fresh node" do
      # ⛔ It raised `ArgumentError: no persistent term stored with this key`, taking
      # SourceDiscoveryJob down on its first live Brave call. Source discovery had therefore never
      # produced a row, and the cause was misread for weeks as a missing API key — the key was
      # present and deployed throughout.
      #
      # The mechanism was a lying default: `get_counter/0` returns `{Date.utc_today(), 0}` for
      # *absent* state, which is indistinguishable from "present, today, zero". The old code read
      # that, concluded the term existed, and then called `:persistent_term.get/1` with no default.
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
      # Budget is per-day, so a stale counter must not carry yesterday's spend forward — and this
      # is the same code path as "absent", which is why the two are one branch.
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
