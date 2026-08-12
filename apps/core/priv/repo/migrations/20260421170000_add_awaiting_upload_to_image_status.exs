defmodule Core.Repo.Migrations.AddAwaitingUploadToImageStatus do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "ALTER TYPE op.image_status ADD VALUE IF NOT EXISTS 'awaiting_upload' BEFORE 'pending'"
    )
  end

  def down do
    :ok
  end
end
