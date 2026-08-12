defmodule Core.Repo.Migrations.Fixture.DropColumn do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books DROP COLUMN cover_image_url;")
  end
end
