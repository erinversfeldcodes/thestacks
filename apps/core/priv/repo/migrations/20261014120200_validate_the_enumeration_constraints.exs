defmodule Core.Repo.Migrations.ValidateTheEnumerationConstraints do
  @moduledoc """
      Validates the five CHECKs added in the previous migration.

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

  def up do
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
  end

  # Validation is not reversible on its own — the constraints themselves are
  # dropped by the previous migration's `down`.
  def down, do: :ok
end
