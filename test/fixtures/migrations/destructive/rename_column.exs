defmodule Core.Repo.Migrations.Fixture.RenameColumn do
  # Fixture: `ALTER TABLE ... RENAME COLUMN`. Should trip `renaming-column`.
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books RENAME COLUMN cover_image_url TO cover_url;")
  end
end
