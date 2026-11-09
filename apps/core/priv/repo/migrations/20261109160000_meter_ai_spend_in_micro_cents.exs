defmodule Core.Repo.Migrations.MeterAiSpendInMicroCents do
  @moduledoc """
      Re-denominate the AI spend ledger in micro-cents.

      ⛔ A CENT IS THE WRONG UNIT FOR A QUANTITY WHOSE NATURAL SCALE IS 10⁻⁵ OF
      ONE, and rounding to it made the ledger wrong in BOTH directions.

      Token pricing is quoted per million. At a plausible 88¢/1M, a 400-token
      completion costs 0.035¢ — so `max(1, ceil(…))` charged it a whole cent,
      roughly **28× over**. The clamp binds on every call under ~50,000 tokens,
      which is every call this system makes except the association worker's; and
      above ~11,400 tokens the old 20¢/1M default under-charged, asymptotically
      by **4.4×**. The association worker's large calls sat in the
      under-charging half.

      ⚖️ Micro-cents removes the clamp by construction rather than by a better
      rounding rule: there is nothing left to round. `bigint` holds a century of
      spend at this scale.

      ⚠️ Safe to re-denominate rather than backfill because this table was
      created today and has never been deployed. Existing rows are scaled so a
      local database stays consistent; the `down` divides back, losing only the
      sub-cent precision that could not be represented before.
  """
  use Ecto.Migration

  def up do
    rename table(:ai_spend, prefix: "op"), :spend_cents, to: :spend_micro_cents

    execute "UPDATE op.ai_spend SET spend_micro_cents = spend_micro_cents * 100000"

    drop constraint(:ai_spend, :spend_is_not_negative, prefix: "op")

    create constraint(:ai_spend, :spend_is_not_negative,
             check: "spend_micro_cents >= 0",
             prefix: "op"
           )
  end

  def down do
    execute "UPDATE op.ai_spend SET spend_micro_cents = spend_micro_cents / 100000"

    drop constraint(:ai_spend, :spend_is_not_negative, prefix: "op")

    rename table(:ai_spend, prefix: "op"), :spend_micro_cents, to: :spend_cents

    create constraint(:ai_spend, :spend_is_not_negative,
             check: "spend_cents >= 0",
             prefix: "op"
           )
  end
end
