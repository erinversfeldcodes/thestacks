defmodule Core.Repo.Migrations.Fixture.SafeAddColumn do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books ADD COLUMN slug text;")
  end
end
