defmodule Stacks.Discovery.BraveClientTest do
  use Core.DataCase, async: true

  alias Stacks.Discovery.BraveClient

  # ⚠️ **A `describe "MockBraveClient.search/2"` block of four tests was removed
  # here (Issue #330).** Each one called `MockBraveClient.put_response(x)` and
  # then asserted `MockBraveClient.search/2` returned `x`. The subject was the
  # test double, not `Stacks.Discovery.BraveClient` — no change to the real
  # client could have reddened them. They asserted that an Agent stores things.
  #
  # Coverage note: nothing was lost. The mock's put/clear machinery is exercised
  # for real by `source_discovery_job_test.exs` and
  # `discover_author_sources_job_test.exs`, which use `put_response` to steer the
  # production `SourceDiscoveryJob` / `DiscoverAuthorSourcesJob` through the
  # behaviour seam — there the mock is a means and the assertion is about
  # production code. The removed tests were never a real guarantee.
  #
  # The describe below is the genuine article and stays: it pins the
  # `persistent_term` bug that took SourceDiscoveryJob down in production.

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
