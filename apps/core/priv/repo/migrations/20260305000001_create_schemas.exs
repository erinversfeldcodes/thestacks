defmodule Core.Repo.Migrations.CreateSchemas do
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS op")
    execute("CREATE SCHEMA IF NOT EXISTS wh")
    execute("CREATE SCHEMA IF NOT EXISTS audit")
    # ALTER DATABASE ... SET search_path only takes effect on NEW connections.
    # The migration runner reuses the current connection for every subsequent
    # migration in the run, so unqualified type/table references in later
    # migrations (e.g. `:user_role` in CreateUsers) would fail on a fresh DB
    # where the session opened before this ALTER ran. Issuing a SET for the
    # current session as well makes the search_path correct for BOTH this
    # connection and any future one.
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
