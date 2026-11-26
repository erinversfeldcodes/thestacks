defmodule Core.Repo.Migrations.ConsentIsABooleanNotATriState do
  @moduledoc """
      Makes `op.users.consent_analytics` and `op.users.consent_writing_assistant`
      `NOT NULL`, which they have always been in meaning and never in schema.

      ## What the third state broke

      Both columns were created with `default: false` and no `NOT NULL`, so a row
      could carry `NULL` — and `GET /api/settings/privacy` sends the column value
      straight through:

          consent_analytics: user.consent_analytics

      The client requires a boolean (`Decode.field "consent_analytics"
      Decode.bool` inside a `Decode.map4`), so a `NULL` fails the decode of the
      WHOLE response. That response seeds the entire privacy screen — profile
      visibility, per-shelf visibility and the consent toggles — so the reader
      would see a transport error instead of the surface on which they manage
      their own privacy. One nullable column, the whole screen.

      ⚠️ Latent rather than live when this landed: measured 0 NULLs in 18 local
      rows and 0 in 2 production rows, and no write path can produce one —
      `GDPRController.update_consent/2` accepts only `true` or `false` and
      `Consent.grant_consent/2`/`revoke_consent/2` write literals. It is fixed at
      the schema because nothing held it, not because it had bitten.

      ## Why NOT NULL rather than coalescing at the serialiser

      `Stacks.GDPR.Consent.consented?/2` already reads the field as `v == true`,
      so the codebase ALREADY treats `NULL` as "not consented" everywhere the
      answer matters. There is no third meaning to preserve — "never consented"
      is recorded by the nullable `*_at` timestamps, which keep their nullability.

      Normalising in the one serialiser would have left every other reader facing
      the same tri-state, and would have made a future `nil` write silently
      become `false` rather than failing loudly at the database. The constraint
      is the guarantee; a coalesce is a patch over one consumer.

      `lock_timeout` because `SET NOT NULL` takes ACCESS EXCLUSIVE on a table on
      every authenticated request path: failing fast is recoverable, queueing
      behind a long transaction is an outage.

      ## ⚠️ `execute`, not `alter … modify` — and this will catch the next person

      Ecto's `modify` emits `ALTER COLUMN … TYPE`, a type change, even when the
      type is identical. A dbt staging view selects this column, so Postgres
      refuses outright:

          ERROR 0A000 cannot alter type of a column used by a view or rule
          rule _RETURN on view staging.stg_users depends on column "consent_analytics"

      `SET NOT NULL` alone changes no type and the view dependency is irrelevant
      to it. **Any `modify` on an `op` column a staging model selects will fail
      this way** — and dbt builds forty staging models over these tables, so that
      is most of them.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # Defensive, and expected to touch nothing. The column defaults have filled
    # every row since creation; this exists so the constraints below cannot fail
    # on a stack whose history we have not measured.
    execute("""
    UPDATE op.users
       SET consent_analytics = coalesce(consent_analytics, false),
           consent_writing_assistant = coalesce(consent_writing_assistant, false)
     WHERE consent_analytics IS NULL
        OR consent_writing_assistant IS NULL
    """)

    execute("ALTER TABLE op.users ALTER COLUMN consent_analytics SET DEFAULT false")
    execute("ALTER TABLE op.users ALTER COLUMN consent_writing_assistant SET DEFAULT false")

    # ⛔ `CHECK … NOT VALID`, not `SET NOT NULL`, and the next migration finishes
    # the job. `SET NOT NULL` scans the whole table under ACCESS EXCLUSIVE, which
    # blocks READS as well as writes for the duration — on `op.users`, every
    # authenticated request. The `lock_timeout` above bounds how long we WAIT for
    # the lock; it does nothing about how long we HOLD it once acquired.
    #
    # ⚖️ A `NOT VALID` check takes the lock only briefly, and Postgres 12+ will
    # then let `SET NOT NULL` use the validated constraint as proof and skip the
    # scan entirely. So the expensive half becomes `VALIDATE CONSTRAINT`, which
    # takes the gentle SHARE UPDATE EXCLUSIVE lock — but ONLY in a different
    # transaction from the ADD, which is why the validation is its own migration
    # and not three more lines here. Same reasoning, same shape, as the three
    # `NOT VALID` constraints validated by `20260730200350`.
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

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # ⚠️ `IF EXISTS`, because the successor migration DROPS these constraints
    # once `SET NOT NULL` has absorbed them — so on a fully-migrated database
    # they are already gone, and on one rolled back only this far they are not.
    execute("ALTER TABLE op.users DROP CONSTRAINT IF EXISTS users_consent_analytics_not_null")

    execute(
      "ALTER TABLE op.users DROP CONSTRAINT IF EXISTS users_consent_writing_assistant_not_null"
    )
  end
end
