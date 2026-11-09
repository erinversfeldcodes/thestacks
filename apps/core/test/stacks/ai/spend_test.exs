defmodule Stacks.AI.SpendTest do
  @moduledoc """
      That the budget survives the thing that used to reset it.

      ⛔ THE DEFECT THIS REPLACES: `BudgetTracker` keeps its totals in GenServer
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
      :ok = Spend.record(:together, 250, @today)

      # Nothing is carried between these two calls but the database — no
      # process state, no cache, no GenServer.
      assert Spend.spent(:together, :daily, @today) == 250
    end

    test "costs accumulate rather than replace" do
      :ok = Spend.record(:together, 100, @today)
      :ok = Spend.record(:together, 50, @today)
      :ok = Spend.record(:together, 7, @today)

      assert Spend.spent(:together, :daily, @today) == 157
    end

    # ⚖️ Not redundant with the case above: a writer that upserted by REPLACING
    # would pass "costs accumulate" only if the last write happened to be the
    # largest. This pins the arithmetic.
    test "the daily and monthly totals move together" do
      :ok = Spend.record(:together, 400, @today)

      assert Spend.spent(:together, :daily, @today) == 400
      assert Spend.spent(:together, :monthly, @today) == 400
    end
  end

  describe "periods are facts about dates, not about timers" do
    # ⛔ THE RESET, WITHOUT A RESET. The old tracker needed a midnight message
    # to arrive at a process that was still alive to receive it; a machine
    # asleep from 23:00 never reset. Here "yesterday" and "today" are simply
    # different rows.
    test "yesterday's spend is not today's" do
      yesterday = Date.add(@today, -1)

      :ok = Spend.record(:together, 900, yesterday)

      assert Spend.spent(:together, :daily, yesterday) == 900

      assert Spend.spent(:together, :daily, @today) == 0,
             "a new day starts at zero because it is a different row — not because " <>
               "something remembered to reset a counter"
    end

    # ⚠️ And the monthly total does NOT reset with the day, which is the half a
    # single counter cannot express at all.
    test "but the month carries across the day boundary" do
      yesterday = Date.add(@today, -1)

      :ok = Spend.record(:together, 300, yesterday)
      :ok = Spend.record(:together, 200, @today)

      assert Spend.spent(:together, :daily, @today) == 200
      assert Spend.spent(:together, :monthly, @today) == 500
    end

    test "a new month starts at zero" do
      last_month = ~D[2026-10-31]

      :ok = Spend.record(:together, 4_000, last_month)

      assert Spend.spent(:together, :monthly, last_month) == 4_000
      assert Spend.spent(:together, :monthly, @today) == 0
    end
  end

  describe "providers are metered separately" do
    test "one provider's spend is not another's" do
      :ok = Spend.record(:together, 100, @today)
      :ok = Spend.record(:modal, 900, @today)

      assert Spend.spent(:together, :daily, @today) == 100
      assert Spend.spent(:modal, :daily, @today) == 900
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
    test "a negative charge is refused by the database" do
      assert_raise Postgrex.Error, fn ->
        Repo.insert_all(Spend, [
          %{
            id: Ecto.UUID.generate(),
            provider: "together",
            period: "daily",
            period_start: @today,
            spend_cents: -500,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end

    test "an unknown period is refused by the database" do
      assert_raise Postgrex.Error, fn ->
        Repo.insert_all(Spend, [
          %{
            id: Ecto.UUID.generate(),
            provider: "together",
            period: "hourly",
            period_start: @today,
            spend_cents: 1,
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
      :ok = Spend.record(:together, 10, @today)

      assert_raise Postgrex.Error, fn ->
        Repo.insert_all(Spend, [
          %{
            id: Ecto.UUID.generate(),
            provider: "together",
            period: "daily",
            period_start: @today,
            spend_cents: 1,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end
  end
end
