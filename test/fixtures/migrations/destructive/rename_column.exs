defmodule Core.Repo.Migrations.Fixture.RenameColumn do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books RENAME COLUMN cover_image_url TO cover_url;")
  end
end
