defmodule Core.Repo.Migrations.EncryptAuditLogMetadata do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        DROP VIEW IF EXISTS staging.stg_audit_log;
      END IF;
    END $$
    """)

    execute("""
    ALTER TABLE audit.audit_log
      ALTER COLUMN metadata TYPE bytea
      USING NULL
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        CREATE OR REPLACE VIEW staging.stg_audit_log AS
          SELECT id, user_id, action, resource_type, resource_id,
                 metadata, ip_address, occurred_at
          FROM audit.audit_log;
      END IF;
    END $$
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        DROP VIEW IF EXISTS staging.stg_audit_log;
      END IF;
    END $$
    """)

    execute("""
    ALTER TABLE audit.audit_log
      ALTER COLUMN metadata TYPE jsonb
      USING NULL
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        CREATE OR REPLACE VIEW staging.stg_audit_log AS
          SELECT id, user_id, action, resource_type, resource_id,
                 metadata, ip_address, occurred_at
          FROM audit.audit_log;
      END IF;
    END $$
    """)
  end
end
