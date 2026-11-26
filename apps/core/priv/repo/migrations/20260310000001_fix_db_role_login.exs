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
    # The passwords travel as bound parameters into transaction-local GUCs, and
    # the ALTER is assembled server-side with `format(%L)`. An earlier version
    # interpolated them straight into the SQL string, which a password holding a
    # quote could break or escape, and left the secret sitting in the statement
    # text. An empty GUC (the secret is unset) falls back to LOGIN without a
    # password, exactly as before. Both statements run in this migration's
    # transaction, so the GUCs set by the first are visible to the second.
    repo().query!(
      "SELECT set_config('stacks.mig_app_pw', $1, true), set_config('stacks.mig_dbt_pw', $2, true)",
      [
        System.get_env("STACKS_APP_DB_PASSWORD") || "",
        System.get_env("STACKS_DBT_DB_PASSWORD") || ""
      ]
    )

    repo().query!("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        IF current_setting('stacks.mig_app_pw') <> '' THEN
          EXECUTE format('ALTER ROLE stacks_app LOGIN PASSWORD %L', current_setting('stacks.mig_app_pw'));
        ELSE
          ALTER ROLE stacks_app LOGIN;
        END IF;
      END IF;
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        IF current_setting('stacks.mig_dbt_pw') <> '' THEN
          EXECUTE format('ALTER ROLE stacks_dbt LOGIN PASSWORD %L', current_setting('stacks.mig_dbt_pw'));
        ELSE
          ALTER ROLE stacks_dbt LOGIN;
        END IF;
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
