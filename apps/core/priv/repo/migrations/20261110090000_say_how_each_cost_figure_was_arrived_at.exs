defmodule Core.Repo.Migrations.SayHowEachCostFigureWasArrivedAt do
  @moduledoc """
      Add `basis` to `op.platform_costs`: measured, rate-card, or absent.

      ⛔ A PUBLIC PAGE SHOWED `$0.00` FOR SERVICES IT HAD NO MEASUREMENT OF,
      UNDER A HEADING CLAIMING EVERY NUMBER ON IT WAS REAL. Five of the eight
      cost-item builders answer an unavailable measurement with
      `amount_cents: 0` — and their own descriptions say so, e.g. Modal's
      "this month's inference count is temporarily unavailable, so no charge is
      shown". The description was right and the number contradicted it. A reader
      seeing zero concludes the thing is free.

      ⚖️ The distinction already existed one layer down and was unreachable.
      `RefreshCostsJob`'s `unwrap/1` says "a measurement we could not take is
      `nil`, never 0 … because a transparency page printing '0' would be
      claiming the service went unused", and every item builder has a nil
      clause. But `Costs.metric_count_this_month/1` converted a metric family
      with no samples into a real `{:ok, 0}` BEFORE that unwrap could see it, so
      the nil clause never fired. That conversion is now gone — and fixing it
      revealed that the builders perform the same conversion themselves, which
      is why this column exists rather than just the upstream fix.

      ⬛ Three states, not two, because the honest answer is not binary:
      `measured` read from a meter, `rate_card` computed from a published price
      and an observed quantity, `absent` no figure for this period. Three of the
      eight nil clauses already fall back to a published constant rather than to
      zero — those are `rate_card`, and conflating them with a measurement would
      be the same dishonesty pointed the other way.

      ⚠️ Default `rate_card`, not `measured`. Every row already on disk was
      written by arithmetic over a price, so `rate_card` is true of them;
      defaulting to `measured` would silently upgrade every historical row to a
      claim nobody checked.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:platform_costs, prefix: "op") do
      add :basis, :string, null: false, default: "rate_card"
    end

    create(
      constraint(:platform_costs, :platform_costs_basis_is_known,
        check: "basis IN ('measured', 'rate_card', 'absent')",
        prefix: "op"
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    drop(constraint(:platform_costs, :platform_costs_basis_is_known, prefix: "op"))

    alter table(:platform_costs, prefix: "op") do
      remove :basis
    end
  end
end
