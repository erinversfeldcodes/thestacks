defmodule Core.Repo.Migrations.StopAutoGrantingNewOpTablesToDbt do
  @moduledoc """
      `stacks_dbt` held an ALTER DEFAULT PRIVILEGES grant of SELECT on every
      FUTURE op table, so a new op table — including one holding personal data —
      became warehouse-readable the moment it was created, and "kept out of the
      warehouse" rested on no dbt model reading it rather than on a privilege
      boundary. Revoke the default grant: a new op table is unreadable by dbt
      until granted deliberately, which is where a reviewer catches a personal
      table heading for the warehouse. Existing op tables keep the SELECT they
      were already granted (a default-privilege change touches only future
      objects), so the warehouse builds unchanged.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        ALTER DEFAULT PRIVILEGES IN SCHEMA op REVOKE SELECT ON TABLES FROM stacks_dbt;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        ALTER DEFAULT PRIVILEGES IN SCHEMA op GRANT SELECT ON TABLES TO stacks_dbt;
      END IF;
    END $$;
    """)
  end
end
