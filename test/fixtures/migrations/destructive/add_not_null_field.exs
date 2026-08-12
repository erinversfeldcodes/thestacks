defmodule Core.Repo.Migrations.Fixture.AddNotNullField do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books ADD COLUMN edition_id uuid NOT NULL;")
  end
end
