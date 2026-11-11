defmodule Core.Repo.Migrations.LetTheAiBudgetOutliveTheNode do
  @moduledoc """
      Spend per provider per period, as rows rather than as process state.

      ⛔ THE BUDGET RESET WHENEVER THE MACHINE IDLED, AND NOTHING SAID SO.
      `Stacks.AI.Budget` (then named `BudgetTracker`) was a GenServer whose
      totals lived in a struct —
      `providers: %{}, daily_total_cents: 0, monthly_total_cents: 0` — with no
      Repo reference anywhere in the module. On a node that scales to zero that
      is not a budget: the ceiling is restored by idling, the restore is
      invisible, and the only way to exceed a daily cap is to stay busy enough
      to keep the node alive.

      ⚠️ ITS DAILY RESET HAS THE SAME SHAPE. `schedule_midnight_reset/0` sends
      itself a message at midnight, which only arrives if the process is still
      there at midnight. A machine asleep from 23:00 to 09:00 never resets —
      and never needed to, having already lost the count.

      ⚖️ A ROW PER PROVIDER PER PERIOD, so the period is a fact in the database
      rather than an interval someone's timer is responsible for. Reading
      "today's spend" becomes a query with a date in it, which is correct
      whether the node has been up for a month or ten seconds.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    create table(:ai_spend, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      # ⚠️ The provider key is kept EXACTLY as the caller passed it, unlike the
      # metric label beside it which collapses unknowns to "other". This is the
      # ledger: it must stay accurate for a provider nobody declared, because
      # money was spent either way.
      add :provider, :text, null: false

      # ⛔ THE PERIOD IS A DATE, NOT A TIMER. `period_start` plus `period` is
      # what makes "today" and "this month" answerable by query. A counter that
      # someone resets on a schedule is only correct while that someone is
      # running — which was the defect.
      add :period, :text, null: false
      add :period_start, :date, null: false

      add :spend_cents, :bigint, null: false, default: 0

      add :created_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    # ⛔ ONE ROW PER PROVIDER PER PERIOD, enforced here rather than by the
    # writer. Two rows for the same day would each hold part of the spend, and
    # a budget check reading one of them would pass while the real total was
    # over — a ceiling that fails open under concurrency, which is the worst
    # direction for this particular table.
    create unique_index(:ai_spend, [:provider, :period, :period_start], prefix: "op")

    create constraint(:ai_spend, :period_is_known,
             check: "period IN ('daily', 'monthly')",
             prefix: "op"
           )

    # ⚠️ Spend cannot go backwards. A negative would silently restore budget,
    # and the one thing a ledger must refuse is an entry that undoes a cost
    # that was really incurred.
    create constraint(:ai_spend, :spend_is_not_negative,
             check: "spend_cents >= 0",
             prefix: "op"
           )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    drop table(:ai_spend, prefix: "op")
  end
end
