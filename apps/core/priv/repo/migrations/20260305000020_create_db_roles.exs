defmodule Core.Repo.Migrations.CreateDbRoles do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        CREATE ROLE stacks_app;
      END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        CREATE ROLE stacks_dbt;
      END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_readonly') THEN
        CREATE ROLE stacks_readonly;
      END IF;
    END $$;
    """)

    # stacks_app: CRUD on op, SELECT on wh, INSERT-only on audit
    execute("GRANT USAGE ON SCHEMA op TO stacks_app")
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA op TO stacks_app")
    execute("ALTER DEFAULT PRIVILEGES IN SCHEMA op GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO stacks_app")
    execute("GRANT USAGE ON SCHEMA wh TO stacks_app")
    execute("GRANT SELECT ON ALL TABLES IN SCHEMA wh TO stacks_app")
    execute("GRANT USAGE ON SCHEMA audit TO stacks_app")
    execute("GRANT INSERT ON ALL TABLES IN SCHEMA audit TO stacks_app")

    # stacks_dbt: SELECT on op, CRUD on wh
    execute("GRANT USAGE ON SCHEMA op TO stacks_dbt")
    execute("GRANT SELECT ON ALL TABLES IN SCHEMA op TO stacks_dbt")
    execute("GRANT USAGE ON SCHEMA wh TO stacks_dbt")
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA wh TO stacks_dbt")
    execute("ALTER DEFAULT PRIVILEGES IN SCHEMA wh GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO stacks_dbt")

    # stacks_readonly: SELECT on op and wh
    execute("GRANT USAGE ON SCHEMA op TO stacks_readonly")
    execute("GRANT SELECT ON ALL TABLES IN SCHEMA op TO stacks_readonly")
    execute("GRANT USAGE ON SCHEMA wh TO stacks_readonly")
    execute("GRANT SELECT ON ALL TABLES IN SCHEMA wh TO stacks_readonly")

    # audit_log: INSERT-only for stacks_app (revoke UPDATE/DELETE explicitly)
    execute("REVOKE UPDATE, DELETE ON audit.audit_log FROM stacks_app")
  end

  def down do
    execute("ALTER DEFAULT PRIVILEGES IN SCHEMA op REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM stacks_app")
    execute("ALTER DEFAULT PRIVILEGES IN SCHEMA wh REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM stacks_dbt")

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

    execute("DROP ROLE IF EXISTS stacks_readonly")
    execute("DROP ROLE IF EXISTS stacks_dbt")
    execute("DROP ROLE IF EXISTS stacks_app")
  end
end
