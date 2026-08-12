defmodule Core.Repo.Migrations.Fixture.AddFieldWithDefault do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books ADD COLUMN flagged boolean DEFAULT 'f' NOT NULL;")
  end
end
