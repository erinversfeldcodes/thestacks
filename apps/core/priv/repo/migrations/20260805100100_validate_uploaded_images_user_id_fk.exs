defmodule Core.Repo.Migrations.ValidateUploadedImagesUserIdFk do
  @moduledoc """
    Validates the `uploaded_images_user_id_fkey` foreign key that
    `20260805100000` added `NOT VALID`.

    Split into its own migration for the same reason as `20260730200350`:
    `ALTER TABLE … VALIDATE CONSTRAINT` only takes the gentle
    `SHARE UPDATE EXCLUSIVE` lock when it runs in a DIFFERENT transaction from the
    `ADD CONSTRAINT … NOT VALID`. `@disable_ddl_transaction` gives it its own
    transaction. Re-running simply re-validates; `down` is a no-op because a
    constraint cannot be un-validated (the constraint itself is dropped by the
    migration that created it).
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("ALTER TABLE op.uploaded_images VALIDATE CONSTRAINT uploaded_images_user_id_fkey")
  end

  def down, do: :ok
end
