defmodule Core.Repo.Migrations.FixDbRoleLogin do
  @moduledoc """
  Ensures stacks_app and stacks_dbt have LOGIN privilege and a password.

  The original create_db_roles migration used bare `CREATE ROLE` which defaults
  to NOLOGIN. dbt and the application need to connect directly with these roles,
  so they must have LOGIN.

  This migration is idempotent — ALTER ROLE is safe to re-run.
  """
  use Ecto.Migration

  def up do
    execute("ALTER ROLE stacks_app LOGIN PASSWORD 'stacks_app'")
    execute("ALTER ROLE stacks_dbt LOGIN PASSWORD 'stacks_dbt'")
    # stacks_dbt needs SELECT on audit schema to build stg_audit_log
    execute("GRANT USAGE ON SCHEMA audit TO stacks_dbt")
    execute("GRANT SELECT ON ALL TABLES IN SCHEMA audit TO stacks_dbt")
    # GRANT CONNECT + CREATE on the current database so:
    #   - stacks_app / stacks_dbt can connect (CONNECT)
    #   - stacks_dbt can create schemas (e.g. wh_staging) at dbt run time (CREATE)
    # Uses current_database() so this works for any db name (stacks_dev, stacks_test, etc.)
    execute("""
    DO $$ BEGIN
      EXECUTE format('GRANT CONNECT ON DATABASE %I TO stacks_app, stacks_dbt, stacks_readonly', current_database());
      EXECUTE format('GRANT CREATE ON DATABASE %I TO stacks_dbt', current_database());
    END $$;
    """)
  end

  def down do
    execute("ALTER ROLE stacks_app NOLOGIN")
    execute("ALTER ROLE stacks_dbt NOLOGIN")
  end
end
