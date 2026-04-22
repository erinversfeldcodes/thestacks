defmodule Core.Repo.Migrations.AddAwaitingUploadToImageStatus do
  use Ecto.Migration

  # Adds a fourth value to the `op.image_status` enum for the
  # presigned-URL upload flow. A client that calls `POST /api/upload/init`
  # gets a row in this state; `POST /api/upload/:id/commit` transitions
  # it to `pending` once R2 confirms the bytes landed.
  #
  # ALTER TYPE ... ADD VALUE must run outside a transaction in Postgres,
  # hence `@disable_ddl_transaction true` and `@disable_migration_lock true`.
  # It is also not reversible — Postgres does not support `DROP VALUE`
  # without rebuilding the type. We ship-forward and treat the old
  # values as a safety subset.
  #
  # `BEFORE 'pending'` places the new value at the start of the enum
  # ordering, which matches the lifecycle: an uploaded image starts in
  # `awaiting_upload`, then moves to `pending` → (`resolved` | `rejected`).
  # Without an explicit position, Postgres appends the value, which
  # sorts it after all terminal states — semantically wrong and also
  # trips the `require-enum-value-ordering` Squawk rule.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "ALTER TYPE op.image_status ADD VALUE IF NOT EXISTS 'awaiting_upload' BEFORE 'pending'"
    )
  end

  def down do
    # No-op — Postgres lacks `DROP VALUE`. Rolling this back would need
    # a type rename + recreate + backfill, which isn't worth automating.
    :ok
  end
end
