defmodule Core.Repo.Migrations.CreateDbRoles do
  use Ecto.Migration

  def up do
    app_password = System.get_env("STACKS_APP_DB_PASSWORD")
    dbt_password = System.get_env("STACKS_DBT_DB_PASSWORD")

    if app_password || dbt_password do
      execute("""
      DO $$ BEGIN
        #{if app_password, do: "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN CREATE ROLE stacks_app LOGIN PASSWORD '#{app_password}'; END IF;", else: ""}
        #{if dbt_password, do: "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN CREATE ROLE stacks_dbt LOGIN PASSWORD '#{dbt_password}'; END IF;", else: ""}
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_readonly') THEN
          CREATE ROLE stacks_readonly NOLOGIN;
        END IF;
      END $$;
      """)
    end

    execute("""
    DO $$ BEGIN
      -- stacks_app: CRUD on op, SELECT on wh, INSERT-only on audit
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT USAGE ON SCHEMA op TO stacks_app;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA op TO stacks_app;
        ALTER DEFAULT PRIVILEGES IN SCHEMA op GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO stacks_app;
        GRANT USAGE ON SCHEMA wh TO stacks_app;
        GRANT SELECT ON ALL TABLES IN SCHEMA wh TO stacks_app;
        GRANT USAGE ON SCHEMA audit TO stacks_app;
        GRANT INSERT ON ALL TABLES IN SCHEMA audit TO stacks_app;
        REVOKE UPDATE, DELETE ON audit.audit_log FROM stacks_app;
      END IF;

      -- stacks_dbt: SELECT on op + audit, CRUD on wh
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        GRANT USAGE ON SCHEMA op TO stacks_dbt;
        GRANT SELECT ON ALL TABLES IN SCHEMA op TO stacks_dbt;
        GRANT USAGE ON SCHEMA audit TO stacks_dbt;
        GRANT SELECT ON ALL TABLES IN SCHEMA audit TO stacks_dbt;
        GRANT USAGE ON SCHEMA wh TO stacks_dbt;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA wh TO stacks_dbt;
        ALTER DEFAULT PRIVILEGES IN SCHEMA wh GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO stacks_dbt;
      END IF;

      -- stacks_readonly: SELECT on op and wh
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_readonly') THEN
        GRANT USAGE ON SCHEMA op TO stacks_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA op TO stacks_readonly;
        GRANT USAGE ON SCHEMA wh TO stacks_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA wh TO stacks_readonly;
      END IF;
    END $$;
    """)
  end

  def down do
    execute(
      "ALTER DEFAULT PRIVILEGES IN SCHEMA op REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM stacks_app"
    )

    execute(
      "ALTER DEFAULT PRIVILEGES IN SCHEMA wh REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM stacks_dbt"
    )

    execute("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA op FROM stacks_app")
    execute("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA wh FROM stacks_app")
    execute("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA audit FROM stacks_app")
    execute("REVOKE USAGE ON SCHEMA op FROM stacks_app")
    execute("REVOKE USAGE ON SCHEMA wh FROM stacks_app")
    execute("REVOKE USAGE ON SCHEMA audit FROM stacks_app")

    execute("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA op FROM stacks_dbt")
    execute("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA wh FROM stacks_dbt")
    execute("REVOKE USAGE ON SCHEMA op FROM stacks_dbt")
    execute("REVOKE USAGE ON SCHEMA wh FROM stacks_dbt")

    execute("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA op FROM stacks_readonly")
    execute("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA wh FROM stacks_readonly")
    execute("REVOKE USAGE ON SCHEMA op FROM stacks_readonly")
    execute("REVOKE USAGE ON SCHEMA wh FROM stacks_readonly")

    execute("""
    DO $$ BEGIN
      BEGIN DROP ROLE IF EXISTS stacks_readonly; EXCEPTION WHEN dependent_objects_still_exist THEN NULL; END;
      BEGIN DROP ROLE IF EXISTS stacks_dbt;      EXCEPTION WHEN dependent_objects_still_exist THEN NULL; END;
      BEGIN DROP ROLE IF EXISTS stacks_app;      EXCEPTION WHEN dependent_objects_still_exist THEN NULL; END;
    END $$;
    """)
  end
end
