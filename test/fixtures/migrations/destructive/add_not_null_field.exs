defmodule Core.Repo.Migrations.Fixture.AddNotNullField do
  # Fixture: `ADD COLUMN ... NOT NULL` with no default. Should trip
  # `adding-not-null-field` — breaks inserts from N-1 code.
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books ADD COLUMN edition_id uuid NOT NULL;")
  end
end
