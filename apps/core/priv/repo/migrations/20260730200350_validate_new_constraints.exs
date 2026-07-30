defmodule Core.Repo.Migrations.ValidateNewConstraints do
  @moduledoc """
  Validates the three constraints Issue #335 added `NOT VALID` — the two owner
  foreign keys from `20260730200200` and the ISBN checksum CHECK from
  `20260730200300`.

  Split into its own migration for one reason: `ALTER TABLE … VALIDATE
  CONSTRAINT` only takes the gentle SHARE UPDATE EXCLUSIVE lock if it runs in a
  DIFFERENT transaction from the `ADD CONSTRAINT … NOT VALID`. Validating in the
  same transaction keeps the ACCESS EXCLUSIVE lock from the ADD held across the
  whole table scan, which is exactly the outage `NOT VALID` exists to avoid —
  squawk's `constraint-missing-not-valid` says so, and said so about the first
  draft of these migrations.

  `@disable_ddl_transaction` gives each statement its own transaction. Nothing
  here is a guard or a data change, so running unwrapped costs nothing: a
  validation that fails leaves the constraint in place and still NOT VALID, and
  re-running the migration simply re-validates.

  A failure here is a data defect, not a migration to relax. `down` is a no-op:
  a constraint cannot be un-validated, and the constraints themselves are
  dropped by the migrations that created them.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "ALTER TABLE op.auth_token_families VALIDATE CONSTRAINT auth_token_families_user_id_fkey"
    )

    execute("ALTER TABLE op.guardian_tokens VALIDATE CONSTRAINT guardian_tokens_user_id_fkey")

    execute("ALTER TABLE op.book_editions VALIDATE CONSTRAINT book_editions_isbn_ean13_checksum")
  end

  def down, do: :ok
end
