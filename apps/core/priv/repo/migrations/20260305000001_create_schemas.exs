defmodule Core.Repo.Migrations.CreateSchemas do
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS op")
    execute("CREATE SCHEMA IF NOT EXISTS wh")
    execute("CREATE SCHEMA IF NOT EXISTS audit")

    execute(
      "DO $$ BEGIN EXECUTE 'ALTER DATABASE ' || current_database() || ' SET search_path TO op, public'; END $$"
    )

    execute("SET search_path TO op, public")
  end

  def down do
    execute(
      "DO $$ BEGIN EXECUTE 'ALTER DATABASE ' || current_database() || ' SET search_path TO public'; END $$"
    )

    execute("DROP SCHEMA IF EXISTS audit CASCADE")
    execute("DROP SCHEMA IF EXISTS wh CASCADE")
    execute("DROP SCHEMA IF EXISTS op CASCADE")
  end
end
