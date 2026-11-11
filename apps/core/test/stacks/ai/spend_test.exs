defmodule Stacks.AI.SpendTest do
  @moduledoc """
      That the budget survives the thing that used to reset it.

      ⛔ THE DEFECT THIS REPLACES: `Budget` keeps its totals in GenServer
      state and touches no database, so on a node that scales to zero the
      ceiling was restored by idling. Every case here is about a total that is
      still there after the process that recorded it is gone.
  """
  use Core.DataCase, async: false

  alias Stacks.AI.Spend

  @today ~D[2026-11-09]

  describe "spend survives the process" do
    # ⛔ THE CASE THE WHOLE TABLE EXISTS FOR. The old tracker would answer 0
    # here, because its total lived in a struct that died with the node.
    test "a restart does not restore the budget" do
      :ok = Spend.record(:together, 25_000_000, @today)

      # Nothing is carried between these two calls but the database — no
      # process state, no cache, no GenServer.
      assert Spend.spent(:together, :daily, @today) == 25_000_000
    end

    test "costs accumulate rather than replace" do
      :ok = Spend.record(:together, 10_000_000, @today)
      :ok = Spend.record(:together, 5_000_000, @today)
      :ok = Spend.record(:together, 700_000, @today)

      assert Spend.spent(:together, :daily, @today) == 15_700_000
    end

    # ⚖️ Not redundant with the case above: a writer that upserted by REPLACING
    # would pass "costs accumulate" only if the last write happened to be the
    # largest. This pins the arithmetic.
    test "the daily and monthly totals move together" do
      :ok = Spend.record(:together, 40_000_000, @today)

      assert Spend.spent(:together, :daily, @today) == 40_000_000
      assert Spend.spent(:together, :monthly, @today) == 40_000_000
    end
  end

  describe "periods are facts about dates, not about timers" do
    # ⛔ THE RESET, WITHOUT A RESET. The old tracker needed a midnight message
    # to arrive at a process that was still alive to receive it; a machine
    # asleep from 23:00 never reset. Here "yesterday" and "today" are simply
    # different rows.
    test "yesterday's spend is not today's" do
      yesterday = Date.add(@today, -1)

      :ok = Spend.record(:together, 90_000_000, yesterday)

      assert Spend.spent(:together, :daily, yesterday) == 90_000_000

      assert Spend.spent(:together, :daily, @today) == 0,
             "a new day starts at zero because it is a different row — not because " <>
               "something remembered to reset a counter"
    end

    # ⚠️ And the monthly total does NOT reset with the day, which is the half a
    # single counter cannot express at all.
    test "but the month carries across the day boundary" do
      yesterday = Date.add(@today, -1)

      :ok = Spend.record(:together, 30_000_000, yesterday)
      :ok = Spend.record(:together, 20_000_000, @today)

      assert Spend.spent(:together, :daily, @today) == 20_000_000
      assert Spend.spent(:together, :monthly, @today) == 50_000_000
    end

    test "a new month starts at zero" do
      last_month = ~D[2026-10-31]

      :ok = Spend.record(:together, 400_000_000, last_month)

      assert Spend.spent(:together, :monthly, last_month) == 400_000_000
      assert Spend.spent(:together, :monthly, @today) == 0
    end
  end

  describe "providers are metered separately" do
    test "one provider's spend is not another's" do
      :ok = Spend.record(:together, 10_000_000, @today)
      :ok = Spend.record(:modal, 90_000_000, @today)

      assert Spend.spent(:together, :daily, @today) == 10_000_000
      assert Spend.spent(:modal, :daily, @today) == 90_000_000
    end
  end

  describe "what it refuses" do
    # ⚠️ A zero costs nothing and should not create a row — otherwise every
    # cache hit writes a ledger entry, and "has this provider been used today"
    # stops being answerable from the table's contents.
    test "a zero charge writes nothing" do
      :ok = Spend.record(:together, 0, @today)

      assert Repo.aggregate(Spend, :count) == 0
    end

    # ⛔ Spend cannot go backwards. A negative would silently restore budget,
    # and the one entry a ledger must refuse is one that undoes a cost really
    # incurred. Guarded at the database, so no writer can bypass it.
    # ⛔ THE CONSTRAINT IS NAMED, BECAUSE A BARE `assert_raise Postgrex.Error`
    # PROVES ONLY THAT SOMETHING RAISED. A probe breaking `@schema_prefix` made
    # every insert raise `undefined_table`, and two of these three cases stayed
    # GREEN against a table that does not exist. Postgrex puts the constraint
    # name in the message, so matching it is what makes the case defend the
    # thing it is named for.
    test "a negative charge is refused by the database" do
      assert_raise Postgrex.Error, ~r/spend_is_not_negative/, fn ->
        Repo.insert_all(Spend, [
          %{
            id: Ecto.UUID.generate(),
            provider: "together",
            period: "daily",
            period_start: @today,
            spend_micro_cents: -500,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end

    test "an unknown period is refused by the database" do
      assert_raise Postgrex.Error, ~r/period_is_known/, fn ->
        Repo.insert_all(Spend, [
          %{
            id: Ecto.UUID.generate(),
            provider: "together",
            period: "hourly",
            period_start: @today,
            spend_micro_cents: 1,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end

    # ⛔ ONE ROW PER PROVIDER PER PERIOD. Two rows for the same day would each
    # hold part of the spend, and a budget check reading one would pass while
    # the real total was over — a ceiling failing OPEN under concurrency, which
    # is the worst direction for this table.
    test "a second row for the same provider and period cannot exist" do
      :ok = Spend.record(:together, 1_000_000, @today)

      assert_raise Postgrex.Error, ~r/ai_spend_provider_period_period_start_index/, fn ->
        Repo.insert_all(Spend, [
          %{
            id: Ecto.UUID.generate(),
            provider: "together",
            period: "daily",
            period_start: @today,
            spend_micro_cents: 1,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end
  end

  describe "metering cannot fail the work it meters" do
    # ⛔ THIS WAS A PROMISE THE CODE DID NOT KEEP, AND NOTHING TESTED IT.
    #
    # `record/3`'s docstring said metering must not fail the work it meters.
    # There was no `rescue`, so an error raised out of
    # `TogetherClient.parse_success_response/1`, crashed the worker, and Oban
    # retried the job — calling and paying for the completion a SECOND time. A
    # metering failure costing a second charge is the exact opposite of the
    # claim.
    #
    # ⚠️ A REAL DATABASE FAULT IS FORCED, not simulated — and the forcing
    # mechanism changed when the rescue was narrowed. These cases used to pass
    # `"not-a-date"` as `today`, which raises out of `Date.beginning_of_month/1`
    # before any SQL runs. The blanket rescue swallowed it, so the tests passed
    # and proved the wrong thing: that a PROGRAMMING error is survivable.
    #
    # ⛔ It no longer is, deliberately. A malformed argument, a renamed column
    # or a wrong `conflict_target` raises on every call, which would swallow
    # every charge, read the ledger as 0, and make `check_budget/1` answer `:ok`
    # to everything — the ceiling gone, fail-OPEN, with only a log line. So the
    # rescue covers `Postgrex.Error` and `DBConnection.ConnectionError` and
    # nothing else, and a value past `bigint` is how a genuine database fault
    # gets raised here.
    test "a database fault returns rather than raising, and says it dropped" do
      # ⚖️ `:dropped`, not `:ok` — the caller needs to know, because the COUNTER
      # is emitted by `Budget.record_cost/2` where the provider vocabulary
      # lives. This function used to emit it itself on an unbounded label.
      assert :dropped = Spend.record(:together, 9_223_372_036_854_775_808, Date.utc_today())
    end

    # ⬛ AND NOTHING IS RECORDED, so the failure is a reporting gap rather than
    # a wrong number. The ceiling is then too generous for as long as the
    # outage lasts — the better of the two failures, because the alternative
    # bills twice for the same answer.
    test "a database fault records nothing rather than something wrong" do
      assert :dropped = Spend.record(:together, 9_223_372_036_854_775_808, Date.utc_today())
      assert Spend.spent(:together, :daily) == 0
    end

    # ⬛ THE COUNTER'S CASE LIVES IN `budget_test.exs` NOW, with the emit. What
    # this file still owns is that the drop is REPORTED — the two halves are
    # deliberately in different modules, so they are asserted where each one
    # happens rather than both here.

    # ⬛ ANTI-VACUITY: a programming error must NOT be swallowed, or the narrowed
    # rescue would be a blanket rescue again.
    test "a malformed argument raises rather than being swallowed" do
      assert_raise FunctionClauseError, fn ->
        Spend.record(:together, 5_000_000, "not-a-date")
      end
    end
  end

  describe "the timestamps answer the questions their names promise" do
    # ⛔ `updated_at` RECORDED CREATION. The upsert's `inc:` touched only the
    # balance, so two charges in one period moved the money and left
    # `updated_at` byte-identical — a column whose name promises the last write
    # and delivered the first. "When was this provider last charged" is the
    # first question anyone asks of a ledger that looks wrong.
    test "a second charge moves updated_at" do
      {:ok, today} = Date.new(2026, 11, 9)

      :ok = Spend.record(:together, 1_000, today)
      [first] = Repo.all(from s in Spend, where: s.period == "daily")

      :ok = Spend.record(:together, 2_000, today)
      [second] = Repo.all(from s in Spend, where: s.period == "daily")

      assert second.spend_micro_cents == 3_000,
             "anti-vacuity: the second charge must actually have landed"

      assert DateTime.compare(second.updated_at, first.updated_at) == :gt,
             "updated_at did not move on the second charge — it is recording creation " <>
               "under a name that promises the latest write"
    end

    # ⬛ AND `created_at` DOES NOT MOVE, or the pair stops being answerable:
    # first-charge and latest-charge would collapse into one fact.
    test "the same charge leaves created_at alone" do
      {:ok, today} = Date.new(2026, 11, 9)

      :ok = Spend.record(:together, 1_000, today)
      [first] = Repo.all(from s in Spend, where: s.period == "daily")

      :ok = Spend.record(:together, 2_000, today)
      [second] = Repo.all(from s in Spend, where: s.period == "daily")

      assert DateTime.compare(second.created_at, first.created_at) == :eq,
             "created_at moved on an update — the row's birthday is no longer recoverable"
    end
  end
end
