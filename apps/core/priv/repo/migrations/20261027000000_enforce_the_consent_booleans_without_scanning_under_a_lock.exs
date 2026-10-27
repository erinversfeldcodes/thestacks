defmodule Core.Repo.Migrations.EnforceTheConsentBooleansWithoutScanningUnderALock do
  @moduledoc """
      Finishes what `20261020090000` started: the two consent booleans become
      `NOT NULL` without a full-table scan held under ACCESS EXCLUSIVE.

      ## Why this is a separate migration and not three more lines

      `VALIDATE CONSTRAINT` only takes the gentle SHARE UPDATE EXCLUSIVE lock
      when it runs in a DIFFERENT transaction from the `ADD CONSTRAINT`.
      Same-transaction validation holds the ADD's ACCESS EXCLUSIVE lock across
      the whole scan — which is the outage `NOT VALID` exists to avoid, so doing
      both in one transaction would leave the pattern with none of its benefit
      and all of its complexity.

      `@disable_ddl_transaction` then puts each `execute` in its own implicit
      transaction, so `VALIDATE` commits before `SET NOT NULL` looks for it.

      ## Why `SET NOT NULL` is cheap here and was not before

      Postgres 12 and later will accept a validated `CHECK (col IS NOT NULL)` as
      proof that no row violates the constraint, and skip the table scan that
      `SET NOT NULL` would otherwise perform. So the expensive work happens
      under the gentle lock, and the strict lock is held only for a catalogue
      update.

      ⚠️ The helper constraints are dropped afterwards. They have served their
      purpose — the column's own `NOT NULL` now carries the guarantee — and
      leaving them would mean every write checked the same predicate twice, with
      the second copy looking like a redundancy nobody could explain.

      ## On the end state

      Identical to what `20261020090000` produced before it was split: both
      columns `NOT NULL` with a `false` default. A database that already ran the
      old form has the columns constrained and no helper constraints, which is
      exactly where this migration leaves a fresh one — so the two histories
      converge rather than diverge.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @breaking_ok "Tightens op.users.consent_analytics and consent_writing_assistant to NOT NULL. " <>
                 "The expand phase shipped in 20261020090000, which set the `false` default and " <>
                 "backfilled every NULL; the columns have defaulted to false since creation and " <>
                 "the changesets have always cast them as booleans, so no N-1 code writes NULL. " <>
                 "Reads already treated NULL as 'not consented' everywhere the answer mattered, " <>
                 "so no reader's behaviour changes."

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = '60s'")

    execute("ALTER TABLE op.users VALIDATE CONSTRAINT users_consent_analytics_not_null")
    execute("ALTER TABLE op.users VALIDATE CONSTRAINT users_consent_writing_assistant_not_null")

    execute("ALTER TABLE op.users ALTER COLUMN consent_analytics SET NOT NULL")
    execute("ALTER TABLE op.users ALTER COLUMN consent_writing_assistant SET NOT NULL")

    execute("ALTER TABLE op.users DROP CONSTRAINT users_consent_analytics_not_null")
    execute("ALTER TABLE op.users DROP CONSTRAINT users_consent_writing_assistant_not_null")
  end

  def down do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = '60s'")

    execute("ALTER TABLE op.users ALTER COLUMN consent_analytics DROP NOT NULL")
    execute("ALTER TABLE op.users ALTER COLUMN consent_writing_assistant DROP NOT NULL")

    # ⚠️ The helper constraints are put back, because this migration dropped
    # them and its predecessor's `down` expects to find them (with `IF EXISTS`,
    # so either order works). Rolling back one step should leave the database in
    # the state the predecessor left it, not in a third state neither migration
    # describes.
    execute("""
    ALTER TABLE op.users
      ADD CONSTRAINT users_consent_analytics_not_null
      CHECK (consent_analytics IS NOT NULL) NOT VALID
    """)

    execute("""
    ALTER TABLE op.users
      ADD CONSTRAINT users_consent_writing_assistant_not_null
      CHECK (consent_writing_assistant IS NOT NULL) NOT VALID
    """)
  end
end
