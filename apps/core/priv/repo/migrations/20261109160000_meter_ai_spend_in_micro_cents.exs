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
      local database stays consistent.

      ⛔ THE `down` ROUNDS UP, AND THAT IS NOT A ROUNDING PREFERENCE. An earlier
      version divided plainly — two `bigint`s, so `/` truncates toward zero.
      Measured in a staged rollback: `99999` micro-cents became **0** cents and
      `150000` became **1**. Every loss went one way, and a down+up round trip
      made it permanent, because `0 * 100000 = 0`. So a deploy rollback followed
      by a re-deploy handed back the daily ceiling.
      
      ⚖️ Which is the same shape as the defect this table exists to fix. The
      budget used to reset whenever the machine idled; after a truncating `down`
      it resets whenever someone rolls back. A ledger that under-counts fails
      OPEN, and the `down` is the artefact that encodes the intent — this one
      encoded the opposite of it. Rounding up matches the bias the ledger
      already states for its own charges.
  """
  use Ecto.Migration

  # ⛔ A RENAME IS DESTRUCTIVE AND `scripts/lint-migrations.sh` IS RIGHT TO ASK.
  # The attestation it wants is exactly the reasoning in the moduledoc above, so
  # it is stated here rather than argued: `op.ai_spend` was created earlier the
  # same day, in `20261109120000`, and has never been deployed — there is no N-1
  # release reading `spend_cents`, and the `UPDATE` below touches only rows a
  # local database holds.
  #
  # ⚠️ `check-schema-diff.sh` cannot see this: it compares final per-table column
  # SETS, so a rename contained within one branch is invisible to it. The linter
  # is the only gate that looks, and it only runs in the `migration-safety` CI
  # job against `origin/main` — not in a local `just ci`. So this was a CI
  # failure that no local run would have surfaced.
  @breaking_ok "op.ai_spend was created the same day and has never been deployed, so no N-1 reader of spend_cents exists"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    rename table(:ai_spend, prefix: "op"), :spend_cents, to: :spend_micro_cents

    execute "UPDATE op.ai_spend SET spend_micro_cents = spend_micro_cents * 100000"

    drop constraint(:ai_spend, :spend_is_not_negative, prefix: "op")

    create constraint(:ai_spend, :spend_is_not_negative,
             check: "spend_micro_cents >= 0",
             prefix: "op"
           )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Round UP: see the moduledoc. Plain integer division truncated toward
    # zero, so sub-cent spend came back as zero and a rollback restored budget.
    execute "UPDATE op.ai_spend SET spend_micro_cents = (spend_micro_cents + 99999) / 100000"

    drop constraint(:ai_spend, :spend_is_not_negative, prefix: "op")

    rename table(:ai_spend, prefix: "op"), :spend_micro_cents, to: :spend_cents

    create constraint(:ai_spend, :spend_is_not_negative,
             check: "spend_cents >= 0",
             prefix: "op"
           )
  end
end
