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
    app_password = System.get_env("STACKS_APP_DB_PASSWORD")
    dbt_password = System.get_env("STACKS_DBT_DB_PASSWORD")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        #{if app_password, do: "ALTER ROLE stacks_app LOGIN PASSWORD '#{app_password}';", else: "ALTER ROLE stacks_app LOGIN;"}
      END IF;
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        #{if dbt_password, do: "ALTER ROLE stacks_dbt LOGIN PASSWORD '#{dbt_password}';", else: "ALTER ROLE stacks_dbt LOGIN;"}
        GRANT USAGE ON SCHEMA audit TO stacks_dbt;
        GRANT SELECT ON ALL TABLES IN SCHEMA audit TO stacks_dbt;
      END IF;
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app')
        OR EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO stacks_app, stacks_dbt, stacks_readonly', current_database());
      END IF;
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        EXECUTE format('GRANT CREATE ON DATABASE %I TO stacks_dbt', current_database());
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        ALTER ROLE stacks_app NOLOGIN;
      END IF;
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        ALTER ROLE stacks_dbt NOLOGIN;
      END IF;
    END $$;
    """)
  end
end
