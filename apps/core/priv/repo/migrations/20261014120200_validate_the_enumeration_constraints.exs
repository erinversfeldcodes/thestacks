defmodule Core.Repo.Migrations.ValidateTheEnumerationConstraints do
  @moduledoc """
      Validates the six CHECKs added by the two previous migrations — the five
      enumerations, plus the import row's `created_at IS NOT NULL`.

      Split out for the reason the lockout-pair constraint was: `VALIDATE
      CONSTRAINT` scans the table under SHARE UPDATE EXCLUSIVE, which lets
      reads and writes continue, whereas adding an already-valid CHECK takes
      ACCESS EXCLUSIVE for the length of the scan. Separate migrations also
      mean an existing row that violates one of these fails HERE, loudly and
      recoverably, rather than at the moment the constraint was created.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @disable_migration_lock true

  # `@disable_ddl_transaction true`, so plain `SET` rather than `SET LOCAL`.
  #
  # `statement_timeout = 0`: a `VALIDATE CONSTRAINT` is a full table scan whose
  # duration is a function of table size, not of anything this migration
  # controls. Bounding it would convert "this deploy took a while" into "this
  # deploy failed", and the scan holds only SHARE UPDATE EXCLUSIVE — readers and
  # writers continue throughout, so there is nothing to protect them from.
  #
  # The `lock_timeout` still matters: acquiring even SHARE UPDATE EXCLUSIVE can
  # queue behind a conflicting lock, and a queued lock request blocks everything
  # that arrives after it.
  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    execute("ALTER TABLE op.platform_costs VALIDATE CONSTRAINT platform_costs_category_known")

    execute(
      "ALTER TABLE op.platform_costs VALIDATE CONSTRAINT platform_costs_amount_not_negative"
    )

    execute("ALTER TABLE op.library_imports VALIDATE CONSTRAINT library_imports_status_known")

    execute(
      "ALTER TABLE op.library_import_rows VALIDATE CONSTRAINT library_import_rows_outcome_known"
    )

    execute(
      "ALTER TABLE op.post_syndications VALIDATE CONSTRAINT post_syndications_target_and_method_known"
    )

    execute(
      "ALTER TABLE op.library_import_rows VALIDATE CONSTRAINT library_import_rows_created_at_present"
    )
  end

  # Validation is not reversible on its own — the constraints themselves are
  # dropped by the previous migration's `down`.
  def down, do: :ok
end
