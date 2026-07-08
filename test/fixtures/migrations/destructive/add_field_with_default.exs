defmodule Core.Repo.Migrations.Fixture.AddFieldWithDefault do
  # Fixture: `ADD COLUMN ... DEFAULT ... NOT NULL`. Should trip
  # `adding-field-with-default` — rewrites every row on older Postgres / large tables.
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books ADD COLUMN flagged boolean DEFAULT 'f' NOT NULL;")
  end
end
